// Transcript variants of a session for the share text API, built by the web
// viewer's own code (web/src/variants.ts, bundled into Resources/transcript.js
// by `pnpm build:jsc`) run in JavaScriptCore, so the stored text is what the
// worker itself would compute. Blocking — call off the main actor.

import Foundation
import JavaScriptCore

enum ShareTranscript {
    /// Transcript text by variant key, or nil when the bundle is missing or the
    /// script throws. `imageBase` is the URL prefix of the share's image
    /// endpoint for this session.
    static func variants(filePath: String, title: String, project: String,
                         sessionId: String, imageBase: String) -> [String: String]? {
        guard let url = Bundle.main.url(forResource: "transcript", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let data = JSONLBytes.read(filePath),
              let context = JSContext() else { return nil }
        var failure: String?
        context.exceptionHandler = { _, exception in
            failure = exception?.toString() ?? "unknown JavaScript exception"
        }
        context.evaluateScript(source)
        guard failure == nil,
              let builder = context.objectForKeyedSubscript("SETranscript")?
                .invokeMethod("create", withArguments: [imageBase]),
              builder.isObject else {
            NSLog("ShareTranscript: bundle failed to load: \(failure ?? "no SETranscript")")
            return nil
        }
        JSONLBytes.forEachLine(data) { line, _, stop in
            builder.invokeMethod("push", withArguments: [String(decoding: line, as: UTF8.self)])
            if failure != nil { stop = true }
        }
        let head = ["title": title, "project": project, "sessionId": sessionId]
        guard failure == nil,
              let result = builder.invokeMethod("finish", withArguments: [head]),
              failure == nil,
              let dict = result.toDictionary() as? [String: String], !dict.isEmpty else {
            NSLog("ShareTranscript: \(failure ?? "malformed result") for \(filePath)")
            return nil
        }
        return dict
    }
}
