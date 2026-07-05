// Sheet for "Share by Link": upload progress → the resulting /s/<id> link with
// Copy, the system share picker (ShareLink), and share revocation.

import SwiftUI

struct ShareSheetView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.shareState {
            case .uploading(let done, let total):
                Text("Sharing sessions").font(.headline)
                ProgressView(value: Double(done), total: Double(max(total, 1))) {
                    Text("Uploading \(done)/\(total)…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(width: 320)

            case .done(let url):
                Text("Share link").font(.headline)
                Text("Anyone with the link can view the sessions. Expires in 30 days.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(url.absoluteString)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .quaternarySystemFill)))
                    Button("Copy") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(url.absoluteString, forType: .string)
                        model.showToast("Link copied")
                    }
                }
                .frame(minWidth: 380)
                HStack {
                    Button("Delete Share", role: .destructive) { model.deleteShare(url) }
                    Spacer()
                    ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                    Button("Done") { model.shareState = nil }
                        .keyboardShortcut(.defaultAction)
                }

            case .failed(let message):
                Text("Share failed").font(.headline)
                Text(message)
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: 380, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Close") { model.shareState = nil }
                        .keyboardShortcut(.defaultAction)
                }

            case nil:
                EmptyView()
            }
        }
        .padding(20)
    }
}
