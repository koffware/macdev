import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SiteStore
    @State private var path = ""

    var body: some View {
        Form {
            Section("Python interpreter") {
                Text("Use the Python installation where MacDev’s dependencies, Click and Rich, are installed.")
                    .foregroundStyle(.secondary)
                TextField("Executable", text: $path, prompt: Text("/absolute/path/to/python3"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        panel.message = "Choose the Python interpreter used by MacDev."
                        if panel.runModal() == .OK, let url = panel.url { path = url.path }
                    }
                    Spacer()
                    Button("Save & Reconnect") { Task { await store.saveInterpreter(path) } }
                        .disabled(store.isBusy || !path.hasPrefix("/"))
                }
                if let error = store.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(width: 560, height: 310)
        .onAppear { path = store.pythonExecutable }
    }
}
