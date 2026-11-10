// Uploading a set of sessions to the web viewer (web/ in this repo, deployed
// on Cloudflare Workers) and returning a public /s/<id> link.
//
// Protocol (see web/worker/index.ts): POST /api/share with session metas →
// {id, ownerToken}; PUT /api/share/<id>/<n>?chunk=<c> with each gzipped jsonl
// body cut into chunks, and PUT /api/share/<id>/<n>?text=<variant> with each
// gzipped transcript variant; POST /api/share/<id>/complete with the chunk
// count and the stored variants of every session. A failed upload is continued
// by the next share of the same sessions: POST /api/share with {resume: <id>}
// returns the hashes of the chunks the server already holds, and matching ones
// are skipped. Owner tokens are kept in UserDefaults so a share the user
// created can later be deleted (DELETE /api/share/<id>).

import CryptoKit
import Foundation

enum ShareService {
    /// Share server base. Overridable via `defaults write … shareServerURL`.
    static var baseURL: URL {
        if let s = UserDefaults.standard.string(forKey: "shareServerURL"),
           let url = URL(string: s), !s.isEmpty {
            return url
        }
        return URL(string: "https://claude-sessions.a-kuz.online")!
    }

    struct ShareError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Server-side cap on one stored chunk (KV value limit minus headroom).
    private static let chunkBytes = 24 * 1024 * 1024

    /// Upload `metas` and return the public share URL. `progress(done, total,
    /// fraction, detail)` is called at each step: sessions fully uploaded,
    /// their total, the overall 0…1 share of the work, and what the current
    /// session is at. Runs entirely off the main actor.
    static func share(_ metas: [SessionMeta],
                      progress: @escaping @Sendable (Int, Int, Double, String) -> Void) async throws -> URL {
        // 1. Create the share: manifest with light session metas.
        let sessions: [[String: Any]] = metas.map { m in
            [
                "name": (m.filePath as NSString).lastPathComponent,
                "title": AutoTitle.displayTitle(m),
                "project": m.projectPath,
                "messageCount": m.messageCount,
                "mtime": Int(m.mtime.timeIntervalSince1970 * 1000),
                "bytes": m.byteSize,
            ]
        }
        let pendingKey = sha256Hex(Data(metas.map { ($0.filePath as NSString).lastPathComponent }
            .joined(separator: "\n").utf8))
        let pending = pendingShare(key: pendingKey)
        var createBody: [String: Any] = ["sessions": sessions]
        if let pending { createBody["resume"] = pending.id }
        let created = try await postJSON(path: "api/share", body: createBody,
                                         ownerToken: pending?.token)
        guard let id = created["id"] as? String,
              let ownerToken = created["ownerToken"] as? String else {
            throw ShareError(message: "malformed create response")
        }
        let uploaded = (created["uploaded"] as? [String: String]) ?? [:]
        setPendingShare(key: pendingKey, id: id, token: ownerToken)

        // 2. Upload each session body, gzipped (the worker stores opaque bytes;
        //    the web client decompresses with DecompressionStream). The gzip
        //    stream is cut into chunks of `chunkBytes`, one request each.
        var chunkCounts: [Int] = []
        var storedTexts: [[String]] = []
        for (n, meta) in metas.enumerated() {
            func report(_ part: Double, _ detail: String, done: Int = n) {
                progress(done, metas.count, (Double(n) + part) / Double(metas.count), detail)
            }
            report(0, "compressing")
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("se-share-\(id)-\(n).gz")
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard Gzip.compress(file: meta.filePath, to: tmp),
                  let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? Int,
                  size > 0,
                  let handle = try? FileHandle(forReadingFrom: tmp) else {
                throw ShareError(message: "failed to gzip \(AutoTitle.displayTitle(meta))")
            }
            defer { try? handle.close() }
            let count = (size + chunkBytes - 1) / chunkBytes
            for c in 0..<count {
                guard let data = try? handle.read(upToCount: chunkBytes), !data.isEmpty else {
                    throw ShareError(message: "failed to read gzip of \(AutoTitle.displayTitle(meta))")
                }
                report(0.95 * Double(c * chunkBytes) / Double(size),
                       "\(megabytes(c * chunkBytes)) of \(megabytes(size)) MB")
                let sha = sha256Hex(data)
                if uploaded["\(n):\(c)"] != sha {
                    var req = request(path: "api/share/\(id)/\(n)", method: "PUT", query: "chunk=\(c)")
                    req.setValue(ownerToken, forHTTPHeaderField: "X-Owner-Token")
                    req.setValue(sha, forHTTPHeaderField: "X-Chunk-SHA256")
                    try await send(req, body: data, retries: uploadRetries)
                }
                let sent = min((c + 1) * chunkBytes, size)
                // The transcript step takes the last 5% of the session's bar.
                report(0.95 * Double(sent) / Double(size),
                       "\(megabytes(sent)) of \(megabytes(size)) MB")
            }
            chunkCounts.append(count)
            report(0.95, "building transcript")
            storedTexts.append(try await uploadTranscripts(
                meta, shareID: id, index: n, ownerToken: ownerToken))
            report(1, "", done: n + 1)
        }

        // 3. Finalize.
        var done = request(path: "api/share/\(id)/complete", method: "POST")
        done.setValue(ownerToken, forHTTPHeaderField: "X-Owner-Token")
        done.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await send(done, body: try JSONSerialization.data(withJSONObject: ["chunks": chunkCounts, "texts": storedTexts]),
                       retries: uploadRetries)
        setPendingShare(key: pendingKey, id: nil, token: nil)

        rememberOwnerToken(id: id, token: ownerToken)
        return baseURL.appendingPathComponent("s/\(id)")
    }

    /// Build the session's transcript variants and upload each gzipped; returns
    /// the keys of the stored ones. A session whose transcript cannot be built
    /// is shared without them: the server then computes the text on request.
    private static func uploadTranscripts(_ meta: SessionMeta, shareID id: String, index n: Int,
                                          ownerToken: String) async throws -> [String] {
        let name = (meta.filePath as NSString).lastPathComponent
        guard let variants = ShareTranscript.variants(
            filePath: meta.filePath,
            title: AutoTitle.displayTitle(meta),
            project: meta.projectPath,
            sessionId: (name as NSString).deletingPathExtension,
            imageBase: baseURL.appendingPathComponent("api/share/\(id)/\(n)/image").absoluteString
        ) else { return [] }
        var stored: [String] = []
        for key in variants.keys.sorted() {
            let dir = FileManager.default.temporaryDirectory
            let txt = dir.appendingPathComponent("se-share-\(id)-\(n)-\(key).txt")
            let gz = dir.appendingPathComponent("se-share-\(id)-\(n)-\(key).txt.gz")
            defer {
                try? FileManager.default.removeItem(at: txt)
                try? FileManager.default.removeItem(at: gz)
            }
            guard (try? Data(variants[key]!.utf8).write(to: txt)) != nil,
                  Gzip.compress(file: txt.path, to: gz),
                  let data = try? Data(contentsOf: gz),
                  !data.isEmpty, data.count <= chunkBytes else { continue }
            var req = request(path: "api/share/\(id)/\(n)", method: "PUT", query: "text=\(key)")
            req.setValue(ownerToken, forHTTPHeaderField: "X-Owner-Token")
            try await send(req, body: data, retries: uploadRetries)
            stored.append(key)
        }
        return stored
    }

    /// Delete a share this app created earlier. Throws if no owner token is known.
    static func deleteShare(url: URL) async throws {
        guard let id = shareID(from: url), let token = ownerToken(id: id) else {
            throw ShareError(message: "no owner token for this share")
        }
        var req = request(path: "api/share/\(id)", method: "DELETE")
        req.setValue(token, forHTTPHeaderField: "X-Owner-Token")
        try await send(req, body: nil)
        forgetOwnerToken(id: id)
    }

    static func shareID(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "s" else { return nil }
        return parts[1]
    }

    // MARK: - owner tokens (for later deletion)

    // MARK: - unfinished uploads (continued by the next share of the same sessions)

    private static let pendingUploadsKey = "sharePendingUploads"

    private static func pendingShare(key: String) -> (id: String, token: String)? {
        guard let all = UserDefaults.standard.dictionary(forKey: pendingUploadsKey) as? [String: [String: String]],
              let id = all[key]?["id"], let token = all[key]?["token"] else { return nil }
        return (id, token)
    }

    private static func setPendingShare(key: String, id: String?, token: String?) {
        var all = (UserDefaults.standard.dictionary(forKey: pendingUploadsKey) as? [String: [String: String]]) ?? [:]
        if let id, let token { all[key] = ["id": id, "token": token] } else { all.removeValue(forKey: key) }
        UserDefaults.standard.set(all, forKey: pendingUploadsKey)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func megabytes(_ bytes: Int) -> Int {
        Int((Double(bytes) / 1_000_000).rounded())
    }

    private static let tokensKey = "shareOwnerTokens"

    static func ownerToken(id: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: tokensKey) as? [String: String])?[id]
    }

    private static func rememberOwnerToken(id: String, token: String) {
        var all = (UserDefaults.standard.dictionary(forKey: tokensKey) as? [String: String]) ?? [:]
        all[id] = token
        UserDefaults.standard.set(all, forKey: tokensKey)
    }

    private static func forgetOwnerToken(id: String) {
        var all = (UserDefaults.standard.dictionary(forKey: tokensKey) as? [String: String]) ?? [:]
        all.removeValue(forKey: id)
        UserDefaults.standard.set(all, forKey: tokensKey)
    }

    // MARK: - HTTP plumbing

    private static func request(path: String, method: String, query: String? = nil) -> URLRequest {
        var url = baseURL.appendingPathComponent(path)
        if let query, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.query = query
            url = parts.url ?? url
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 120
        return req
    }

    private static func postJSON(path: String, body: [String: Any],
                                 ownerToken: String? = nil) async throws -> [String: Any] {
        var req = request(path: path, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let ownerToken { req.setValue(ownerToken, forHTTPHeaderField: "X-Owner-Token") }
        let data = try await send(req, body: try JSONSerialization.data(withJSONObject: body))
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ShareError(message: "malformed server response")
        }
        return obj
    }

    /// Repeats of an idempotent upload request after a failure.
    private static let uploadRetries = 4

    /// Perform the request, throwing the server's `{error}` message on non-2xx.
    /// A transport failure (connection lost, timeout) or a 5xx/429 answer is
    /// retried up to `retries` times with a growing pause; pass it only for
    /// idempotent requests.
    @discardableResult
    private static func send(_ req: URLRequest, body: Data?, retries: Int = 0) async throws -> Data {
        var data = Data()
        var resp = URLResponse()
        var attempt = 0
        while true {
            do {
                if let body {
                    (data, resp) = try await URLSession.shared.upload(for: req, from: body)
                } else {
                    (data, resp) = try await URLSession.shared.data(for: req)
                }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code >= 500 || code == 429, attempt < retries else { break }
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            } catch {
                guard attempt < retries else { throw ShareError(message: error.localizedDescription) }
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            }
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let serverMsg = ((try? JSONSerialization.jsonObject(with: data))
                as? [String: Any])?["error"] as? String
            throw ShareError(message: serverMsg ?? "HTTP \(status)")
        }
        return data
    }
}
