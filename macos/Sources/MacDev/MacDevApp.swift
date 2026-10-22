import SwiftUI
import AppKit

@main
struct MacDevApp: App {
    @StateObject private var store = SiteStore()

    var body: some Scene {
        WindowGroup {
            SitesView(store: store)
                .frame(minWidth: 780, minHeight: 520)
                .task { await store.refresh() }
        }
        .defaultSize(width: 1040, height: 680)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit MacDev") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q").disabled(store.isBusy)
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Sites") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(store.isBusy)
            }
        }
        Settings {
            SettingsView(store: store)
        }
    }
}
