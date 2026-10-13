import MochiCore
import SwiftUI

/// Which words of the practice sentence the latest attempt got across. A hint, not a score: each word carries an
/// icon and the legend names it, so no state is told by colour alone.
struct AttemptCheckView: View {
    @Bindable var app: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What Mochi caught").font(.headline)
            switch app.help.attemptCheck {
            case .none:
                EmptyView()
            case .checked(let check):
                checked(check)
            case .needsDownload:
                Text(
                    "To see which words Mochi caught, download Apple’s English speech model. It downloads once, from Apple."
                ).font(.callout).foregroundStyle(.secondary)
                Button("Download Speech Model", action: app.downloadSpeechModel).disabled(app.busy)
            case .unavailable(.olderMacOS):
                note("Word checks need macOS 26 or later.")
            case .unavailable(.language):
                note("Word checks are available for English sentences only.")
            case .unavailable(.recognizer):
                note("Speech recognition is not available on this Mac.")
            case .failed:
                note("Mochi could not check this attempt. The attempt itself is saved.")
            }
        }
    }
    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }
    @ViewBuilder private func checked(_ check: AttemptCheck) -> some View {
        if check.anythingHeard {
            Text("Words caught: \(check.count(.heard)) of \(check.words.count)").font(.callout)
            WrappingStack(spacing: 6) {
                ForEach(Array(check.words.enumerated()), id: \.offset) { _, word in
                    WordChip(word: word)
                }
            }
            if !check.extra.isEmpty {
                Text("Also heard: \(check.extra.joined(separator: " "))").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                ForEach(WordChip.Look.allCases, id: \.self) { look in
                    Label {
                        Text(look.name)
                    } icon: {
                        look.icon
                    }
                }
            }.font(.caption).foregroundStyle(.secondary)
            Text(
                "From Apple speech recognition on this Mac. It also misses some words said well, so treat this as a hint, not a score."
            ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            note("Mochi did not catch any words. Speak a little closer to the microphone and try again.")
        }
    }
}

private struct WordChip: View {
    enum Look: CaseIterable {
        case heard, heardAs, notCaught, unclear
        var name: LocalizedStringKey {
            switch self {
            case .heard: "Heard"
            case .heardAs: "Heard as another word"
            case .notCaught: "Not caught"
            case .unclear: "Unclear"
            }
        }
        var icon: some View {
            let (symbol, tint): (String, Color) =
                switch self {
                case .heard: ("checkmark.circle", .green)
                case .heardAs: ("arrow.left.arrow.right.circle", .orange)
                case .notCaught: ("minus.circle", .red)
                case .unclear: ("questionmark.circle", .secondary)
                }
            return Image(systemName: symbol).foregroundStyle(tint)
        }
    }
    let word: AttemptCheck.Word
    private var look: Look {
        switch word.state {
        case .heard: .heard
        case .heardAs: .heardAs
        case .notCaught: .notCaught
        case .uncertain: .unclear
        }
    }
    /// What the recognizer returned, shown under the word when it differs from it.
    private var recognized: String? {
        switch word.state {
        case .heardAs(let other): other
        case .uncertain(let other): AttemptCheck.sameWords(other, word.text) ? nil : other
        case .heard, .notCaught: nil
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                look.icon.accessibilityLabel(Text(look.name))
                Text(verbatim: word.text).foregroundStyle(look == .notCaught ? .secondary : .primary)
            }
            if let recognized {
                Text(verbatim: "“\(recognized)”").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }
}

/// Lays children out left to right, wrapping onto a new line when the next one does not fit.
private struct WrappingStack: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(
            width: rows.map(\.width).max() ?? 0,
            height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
