// Uploading a set of sessions to the web viewer (web/ in this repo, deployed
// on Cloudflare Workers) and returning a public /s/<id> link.
//
// Protocol (see web/worker/index.ts): POST /api/share with session metas →
// {id, ownerToken}; PUT /api/share/<id>/<n>?chunk=<c> with each gzipped jsonl
// body cut into chunks; POST /api/share/<id>/complete with the chunk count of
// every session. Owner tokens are kept in UserDefaults so a
// share the user created can later be deleted (DELETE /api/share/<id>).

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
    /// fraction)` is called after each uploaded chunk: sessions fully uploaded,
    /// their total, and the overall 0…1 share of the work. Runs entirely off
    /// the main actor.
    static func share(_ metas: [SessionMeta],
                      progress: @escaping @Sendable (Int, Int, Double) -> Void) async throws -> URL {
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
        let created = try await postJSON(path: "api/share", body: ["sessions": sessions])
        guard let id = created["id"] as? String,
              let ownerToken = created["ownerToken"] as? String else {
            throw ShareError(message: "malformed create response")
        }

        // 2. Upload each session body, gzipped (the worker stores opaque bytes;
        //    the web client decompresses with DecompressionStream). The gzip
        //    stream is cut into chunks of `chunkBytes`, one request each.
        var chunkCounts: [Int] = []
        for (n, meta) in metas.enumerated() {
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
                var req = request(path: "api/share/\(id)/\(n)", method: "PUT", query: "chunk=\(c)")
                req.setValue(ownerToken, forHTTPHeaderField: "X-Owner-Token")
                try await send(req, body: data)
                let finished = c + 1 == count
                progress(finished ? n + 1 : n, metas.count,
                         (Double(n) + Double(c + 1) / Double(count)) / Double(metas.count))
            }
            chunkCounts.append(count)
        }

        // 3. Finalize.
        var done = request(path: "api/share/\(id)/complete", method: "POST")
        done.setValue(ownerToken, forHTTPHeaderField: "X-Owner-Token")
        done.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await send(done, body: try JSONSerialization.data(withJSONObject: ["chunks": chunkCounts]))

        rememberOwnerToken(id: id, token: ownerToken)
        return baseURL.appendingPathComponent("s/\(id)")
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

    private static func postJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
        var req = request(path: path, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try await send(req, body: try JSONSerialization.data(withJSONObject: body))
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ShareError(message: "malformed server response")
        }
        return obj
    }

    /// Perform the request, throwing the server's `{error}` message on non-2xx.
    @discardableResult
    private static func send(_ req: URLRequest, body: Data?) async throws -> Data {
        let data: Data
        let resp: URLResponse
        do {
            if let body {
                (data, resp) = try await URLSession.shared.upload(for: req, from: body)
            } else {
                (data, resp) = try await URLSession.shared.data(for: req)
            }
        } catch {
            throw ShareError(message: error.localizedDescription)
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
