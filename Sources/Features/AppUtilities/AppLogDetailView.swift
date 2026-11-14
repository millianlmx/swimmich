import SwiftUI

/// One log line, whole (gap G24).
///
/// Four blocks, each rendered only when it has something in it — the same rule
/// the upstream page follows: the message always, the failure's full text when
/// there is one, the origin always, and the call symbols only when the transport
/// caught a thrown error.
struct AppLogDetailView: View {
    let entry: AppLogEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PVSpacing.s16) {
                LogTextBlock(section: "message", header: "MESSAGE", value: entry.message)
                if let details = entry.details {
                    LogTextBlock(section: "details", header: "DETAILS", value: details)
                }
                LogTextBlock(section: "from", header: "FROM", value: entry.category)
                if let stack = entry.stack {
                    LogTextBlock(section: "stack", header: "STACK TRACE", value: stack)
                }
            }
            .padding(PVSpacing.s16)
        }
        .navigationTitle("Log Entry")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One copyable block. The monospace face lives here and nowhere else on these
/// screens: a call stack is read in a fixed pitch or not read at all.
private struct LogTextBlock: View {
    /// Names the copy button's accessibility identifier (`copyLogBlock_<section>`).
    let section: String
    let header: LocalizedStringKey
    let value: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s8) {
            HStack(spacing: PVSpacing.s8) {
                Text(header)
                    .font(.pvHeadline)
                    .foregroundStyle(Color.textSecondaryPV)
                Spacer()
                Button {
                    UIPasteboard.general.string = value
                    copied = true
                } label: {
                    if copied {
                        Label("Copied to clipboard", systemImage: "checkmark")
                    } else {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
                .font(.pvCaption)
                .foregroundStyle(Color.immichPrimary)
                .accessibilityIdentifier("copyLogBlock_\(section)")
            }

            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.textPrimaryPV)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The very text the copy button writes (L-28, AC-338).
                .accessibilityIdentifier("logBlockText_\(section)")
        }
        .padding(PVSpacing.s12)
        .background(Color.bgSecondary, in: RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous))
    }
}
