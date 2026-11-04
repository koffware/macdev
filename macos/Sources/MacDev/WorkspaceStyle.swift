import AppKit
import SwiftUI

extension View {
    @ViewBuilder func workspaceToolbarTitleHidden() -> some View {
        if #available(macOS 15, *) {
            self.toolbar(removing: .title)
        } else {
            self.navigationTitle("")
        }
    }
}

struct WorkspacePanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
    }
}

struct PathText: View {
    let value: String

    var body: some View {
        Text(value)
            .font(.system(.callout, design: .monospaced))
            .lineLimit(1).truncationMode(.middle)
            .textSelection(.enabled).help(value)
    }
}

struct ContextHelp: View {
    let message: String
    @State private var isPresented = false

    init(_ message: String) { self.message = message }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(message)
        .accessibilityLabel("More information")
        .accessibilityHint(message)
        .popover(isPresented: $isPresented) {
            Text(message).font(.callout).padding(16).frame(width: 300)
        }
    }
}

private struct AddSiteKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var addSite: (() -> Void)? {
        get { self[AddSiteKey.self] }
        set { self[AddSiteKey.self] = newValue }
    }
}
