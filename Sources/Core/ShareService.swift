// Uploading a set of sessions to the web viewer (web/ in this repo, deployed
// on Cloudflare Workers) and returning a public /s/<id> link.
//
// Protocol (see web/worker/index.ts): POST /api/share with session metas →
// {id, ownerToken}; PUT /api/share/<id>/<n> with each gzipped jsonl body;
// POST /api/share/<id>/complete. Owner tokens are kept in UserDefaults so a
// share the user created can later be deleted (DELETE /api/share/<id>).

import Foundation

enum ShareService {
    /// Share server base. Overridable via `defaults write … shareServerURL`.
    static var baseURL: URL {
        if let s = UserDefaults.standard.string(forKey: "shareServerURL"),
           let url = URL(string: s), !s.isEmpty {
            return url
        }
        return URL(string: "https://session-explorer.erpprog.workers.dev")!
    }

    struct ShareError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Server-side cap on one gzipped session (KV value limit minus headroom).
    private static let maxPartBytes = 24 * 1024 * 1024

    /// Upload `metas` and return the public share URL. `progress(done, total)`
    /// is called after each uploaded session. Runs entirely off the main actor.
    static func share(_ metas: [SessionMeta],
                      progress: @escaping @Sendable (Int, Int) -> Void) async throws -> URL {
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
        //    the web client decompresses with DecompressionStream).
        for (n, meta) in metas.enumerated() {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("se-share-\(id)-\(n).gz")
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard Gzip.compress(file: meta.filePath, to: tmp),
                  let data = try? Data(contentsOf: tmp) else {
                throw ShareError(message: "failed to gzip \(AutoTitle.displayTitle(meta))")
            }
            if data.count > maxPartBytes {
                throw ShareError(message:
                    "\(AutoTitle.displayTitle(meta)) is too large to share (\(data.count / 1_000_000) MB gzipped, max \(maxPartBytes / 1_000_000) MB)")
            }
            var req = request(path: "api/share/\(id)/\(n)", method: "PUT")
            req.setValue(ownerToken, forHTTPHeaderField: "X-Owner-Token")
            try await send(req, body: data)
            progress(n + 1, metas.count)
        }

        // 3. Finalize.
        var done = request(path: "api/share/\(id)/complete", method: "POST")
        done.setValue(ownerToken, forHTTPHeaderField: "X-Owner-Token")
        try await send(done, body: Data())

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

    private static func request(path: String, method: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
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
