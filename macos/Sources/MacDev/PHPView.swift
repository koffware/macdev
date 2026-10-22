import MacDevCore
import SwiftUI

struct PHPView: View {
    @ObservedObject var store: SiteStore
    @State private var tab = "settings"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("PHP").font(.largeTitle.weight(.semibold))
                Spacer()
                Picker("Version", selection: $store.phpVersion) {
                    ForEach(store.phpVersions, id: \.self) { Text("PHP \($0)").tag($0) }
                }.frame(width: 190).disabled(store.isBusy)
                Button { Task { await store.loadPHP() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(store.isBusy || store.isLoadingPHP)
            }
            Picker("PHP management", selection: $tab) {
                Text("Configuration").tag("settings")
                Text("Extensions").tag("extensions")
            }.pickerStyle(.segmented)
            if store.isLoadingPHP { ProgressView("Reading PHP \(store.phpVersion)…") }
            if let error = store.phpError {
                ScrollView { Text(error).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
            if let details = store.phpDetails {
                if tab == "settings" { PHPSettingsEditor(store: store, details: details).id(details.revision) }
                else { ExtensionsView(store: store, details: details) }
            } else if store.phpVersions.isEmpty {
                ContentUnavailableView("No PHP versions installed", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Spacer(minLength: 0)
        }
        .padding(26)
        .task(id: store.phpVersion) { await store.loadPHP() }
    }
}

private struct PHPSettingsEditor: View {
    @ObservedObject var store: SiteStore
    let details: PHPDetails
    @State private var values: [String: String] = [:]
    private let fields = [("memory_limit", "Memory limit", "512M"),
                          ("upload_max_filesize", "Maximum upload size", "64M"),
                          ("post_max_size", "Maximum POST size", "64M"),
                          ("max_execution_time", "Execution timeout (seconds)", "30"),
                          ("max_input_vars", "Maximum input variables", "1000")]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Defaults for sites using PHP \(details.version)").font(.headline)
                Form {
                    ForEach(fields, id: \.0) { key, title, example in
                        TextField(title, text: Binding(get: { values[key] ?? "" }, set: { values[key] = $0 }), prompt: Text(example))
                    }
                    Toggle("Display PHP errors", isOn: Binding(
                        get: { ["on", "1"].contains((values["display_errors"] ?? "").lowercased()) },
                        set: { values["display_errors"] = $0 ? "On" : "Off" }
                    ))
                }.textFieldStyle(.roundedBorder)
                Text("Memory and size fields accept values such as 128M or 1G. A memory limit of -1 and an execution timeout of 0 mean unlimited. Saving validates PHP and restarts this version’s service if it is running.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Save Configuration") { Task { _ = await store.savePHP(details, values: values) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy || values == details.settings || values.isEmpty)
                Divider()
                Text("FPM configuration").font(.headline)
                Text(details.iniPath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Show Configuration in Finder") { store.revealFile(details.iniPath) }
                Text("Changes are stored in a separate MacDev INI file. These are FPM defaults; individual pool or project settings may override them. The terminal may use a different php-cli.ini.")
                    .font(.caption).foregroundStyle(.secondary)
                if let diagnostics = details.diagnostics {
                    Text(diagnostics).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
        }
        .onAppear { values = details.settings }
        .disabled(store.isBusy || store.isLoadingPHP)
    }
}

private struct ExtensionsView: View {
    @ObservedObject var store: SiteStore
    let details: PHPDetails
    @State private var search = ""
    @State private var installing = false
    @State private var removing: PHPExtension?

    private var extensions: [PHPExtension] {
        details.extensions.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Find an extension", text: $search).textFieldStyle(.roundedBorder)
                Button("Install Extension…") { installing = true }
                    .disabled(store.isBusy || store.isLoadingPHP || !details.installerAvailable)
            }
            List(extensions) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).fontWeight(.medium)
                        Text(item.builtin ? "Built into PHP" : (item.enabled ? (item.loaded ? "Enabled" : "Enabled · Not loaded") : "Disabled") + (item.version.map { " · \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.canSeparateIni == true {
                        Button("Separate INI") {
                            Task { _ = await store.manageExtension(details, name: item.id, action: "separate-ini") }
                        }
                        .help("Move the load directive to its own INI file, keeping the extension’s enabled state")
                    } else if let path = item.iniPath, !item.builtin {
                        Button { store.revealFile(path) } label: { Image(systemName: "doc.text") }
                            .help("Show extension INI in Finder").accessibilityLabel("Show extension INI in Finder")
                    }
                    if item.canToggle {
                        Button(item.enabled ? "Disable" : "Enable") {
                            Task { _ = await store.manageExtension(details, name: item.id, action: item.enabled ? "disable" : "enable") }
                        }
                    }
                    if item.canRemove {
                        Button("Remove…", role: .destructive) { removing = item }
                    }
                }.padding(.vertical, 5).disabled(store.isBusy || store.isLoadingPHP)
            }.listStyle(.inset)
            Text("New installations use a separate INI file per extension. Use Separate INI to move existing load directives out of php.ini and consolidate duplicates. Built-in modules cannot be removed; only PECL packages can be uninstalled here.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $installing) { ExtensionInstaller(store: store, details: details) }
        .confirmationDialog("Remove \(removing?.package ?? removing?.name ?? "extension") from PHP \(details.version)?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            if let extensionToRemove = removing {
                Button("Remove Extension", role: .destructive) {
                    Task { _ = await store.manageExtension(details, name: extensionToRemove.id, action: "remove") }
                }
            }
        } message: { Text("The extension will be disabled, then uninstalled using this PHP version’s PECL registry. Sites that depend on it may stop working.") }
    }
}

private struct ExtensionInstaller: View {
    @ObservedObject var store: SiteStore
    let details: PHPDetails
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Install Extension for PHP \(details.version)").font(.title2.weight(.semibold))
            TextField("PECL package name", text: $name, prompt: Text("redis, xdebug, imagick…"))
                .textFieldStyle(.roundedBorder).disabled(store.isBusy)
            Text("Downloads and builds the package using this PHP version’s tools, then enables each module in its own INI file. Build tools and required system libraries must already be installed. Installation can take several minutes.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = store.error {
                ScrollView { Text(error).foregroundStyle(.red).textSelection(.enabled) }.frame(maxHeight: 150)
            }
            HStack {
                if store.isBusy { ProgressView().controlSize(.small); Text("Installing…").font(.caption) }
                Spacer()
                Button("Cancel") { dismiss() }.disabled(store.isBusy).keyboardShortcut(.cancelAction)
                Button("Install") {
                    Task {
                        if await store.manageExtension(details, name: name.trimmingCharacters(in: .whitespaces), action: "install") { dismiss() }
                    }
                }
                .disabled(store.isBusy || name.isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 560)
        .interactiveDismissDisabled(store.isBusy)
        .onAppear { store.error = nil }
    }
}
