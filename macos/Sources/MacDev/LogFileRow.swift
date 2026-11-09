import MacDevCore
import SwiftUI

/// One log file inside a `WorkspacePanel`, with its most recent lines on request.
struct LogFileRow: View {
    let title: String
    let path: String
    let exists: Bool
    let size: Int64?
    let modified: Date?
    let open: () -> Void
    let read: () async -> Result<LogTail, Error>
    @State private var isExpanded = false
    @State private var isLoading = false
    @State private var lines: [String]?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text(title).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                Text(summary).foregroundStyle(exists ? .primary : .secondary).help(path)
                Spacer(minLength: 0)
                if exists {
                    Button(isExpanded ? "Hide Recent" : "Show Recent") {
                        isExpanded.toggle()
                        if isExpanded { Task { await load() } }
                    }
                    .help("Show the last lines of this log")
                    Button(action: open) {
                        Label("Open", systemImage: "doc.text.magnifyingglass")
                    }
                    .help("Open the whole log in Console")
                }
            }
            .frame(minHeight: 22)
            if isExpanded { recent }
        }
        .padding(16)
    }

    private var summary: String {
        guard exists else { return "Not created yet" }
        let size = size.map { $0 == 0 ? "Empty" : ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let updated = modified.map { "updated \($0.formatted(.relative(presentation: .named)))" }
        return [size, updated].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var recent: some View {
        if let error {
            Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        } else if let lines {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView([.vertical, .horizontal]) {
                    Text(lines.isEmpty ? "This log is empty." : lines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(lines.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .defaultScrollAnchor(.bottom)
                .frame(maxHeight: 220)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                HStack {
                    Text("Last \(lines.count) \(lines.count == 1 ? "line" : "lines")").font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reload") { Task { await load() } }.controlSize(.small).disabled(isLoading)
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        switch await read() {
        case .success(let tail):
            lines = tail.lines
            error = nil
        case .failure(let failure):
            error = failure.localizedDescription
        }
    }
}
