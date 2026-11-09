import AppKit
import SwiftUI

@main
struct MacDevApp: App {
    @StateObject private var store = SiteStore()
    @AppStorage("appearance") private var appearance: AppAppearance = .auto

    var body: some Scene {
        WindowGroup {
            Group {
                if store.isStarting {
                    StartupView(status: store.startupStatus)
                } else {
                    SitesView(store: store)
                }
            }
            .frame(minWidth: 980, minHeight: 600)
            .preferredColorScheme(appearance.colorScheme)
            .task { await store.preload() }
        }
        .defaultSize(width: 1240, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit MacDev") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q").disabled(store.isBusy)
            }
            WorkspaceCommands(store: store)
        }
        Settings {
            SettingsView(store: store)
        }
    }
}

private struct WorkspaceCommands: Commands {
    @ObservedObject var store: SiteStore
    @FocusedValue(\.addSite) private var addSite

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Site…") { addSite?() }
                .keyboardShortcut("n").disabled(addSite == nil)
        }
        CommandGroup(after: .newItem) {
            Button("Refresh") { Task { await store.refreshCurrentSection() } }
                .keyboardShortcut("r")
                .disabled(
                    store.isStarting || store.isBusy || store.isLoadingPHP || store.isLoadingServices
                        || store.isLoadingDocker)
        }
    }
}
