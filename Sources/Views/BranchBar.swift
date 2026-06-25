import SwiftUI

/// A small control shown above a block that begins a branch (its parent message
/// has ≥2 children, e.g. from `/regenerate`). In `.switcher` mode it lets the
/// reader pick which alternative to follow; in `.tree` mode it labels which
/// alternative this run is, so every branch reads in place.
struct BranchBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.s) private var s
    /// The branch's first message id (= the block id).
    let firstMessageID: String

    var body: some View {
        let alts = model.branchAlternatives(forFirstMessageID: firstMessageID)
        if alts.count > 1 {
            switch model.branchMode {
            case .switcher: switcher(alts)
            case .tree: treeLabel(alts)
            case .activeOnly: EmptyView()
            }
        }
    }

    // MARK: switcher — pills that swap the active path.

    private func switcher(_ alts: [AppModel.BranchAlternative]) -> some View {
        HStack(spacing: s(6)) {
            Image(systemName: "arrow.triangle.branch")
                .scaledFont(11, weight: .semibold)
                .foregroundStyle(Theme.accent)
            ForEach(alts) { alt in
                Button { model.chooseBranch(childID: alt.id) } label: {
                    Text("\(alt.index)/\(alt.total)")
                        .scaledFont(11, weight: alt.isActive ? .bold : .medium, design: .monospaced)
                        .foregroundStyle(alt.isActive ? .white : Theme.accent)
                        .padding(.horizontal, s(8)).padding(.vertical, s(2))
                        .background(
                            RoundedRectangle(cornerRadius: s(5))
                                .fill(alt.isActive ? Theme.accent : Theme.accent.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help(alt.preview)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, s(10)).padding(.vertical, s(5))
        .background(RoundedRectangle(cornerRadius: s(7)).fill(Theme.accent.opacity(0.06)))
    }

    // MARK: tree — a labelled separator before each alternative run.

    private func treeLabel(_ alts: [AppModel.BranchAlternative]) -> some View {
        let mine = alts.first { $0.id == firstMessageID }
        return HStack(spacing: s(6)) {
            Image(systemName: "arrow.triangle.branch")
                .scaledFont(10.5, weight: .semibold)
            Text("ветка \(mine?.index ?? 1) из \(mine?.total ?? alts.count)")
                .scaledFont(11, weight: .semibold)
            Rectangle().fill(Theme.accent.opacity(0.25)).frame(height: 1)
        }
        .foregroundStyle(Theme.accent)
        .padding(.vertical, s(3))
    }
}
