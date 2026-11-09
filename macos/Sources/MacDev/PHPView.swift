import MacDevCore
import SwiftUI

private enum PHPTab: String, CaseIterable {
    case overview = "Overview"
    case settings = "Settings"
    case extensions = "Extensions"
}

/// PHP treats these spellings of a boolean INI value as on.
func phpFlag(_ value: String?) -> Bool { ["on", "1", "yes", "true"].contains((value ?? "").lowercased()) }

struct PHPView: View {
    @ObservedObject var store: SiteStore
    @State private var tab = PHPTab.overview
    @State private var installerName: String?
    @State private var confirmingTerminal = false
    @State private var stopping: Service?

    private var version: String { store.phpVersion }
    private var details: PHPDetails? { store.phpDetails.flatMap { $0.version == version ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if store.phpVersions.isEmpty {
                ContentUnavailableView(
                    "No PHP versions installed", systemImage: "chevron.left.forwardslash.chevron.right",
                    description: Text("Install PHP with Homebrew, for example brew install php@8.4, then refresh."))
            } else if !version.isEmpty {
                header
                Picker("PHP management", selection: $tab) {
                    ForEach(PHPTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                if store.isLoadingPHP && details == nil { ProgressView("Reading PHP \(version)…") }
                if let error = store.phpError {
                    ScrollView {
                        Text(error).foregroundStyle(.red).textSelection(.enabled).frame(
                            maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 160)
                }
                if let details {
                    switch tab {
                    case .overview:
                        PHPOverview(
                            store: store, details: details,
                            onInstall: { installerName = $0 }, onUseInTerminal: { confirmingTerminal = true })
                    case .settings: PHPSettingsEditor(store: store, details: details).id(details.revision)
                    case .extensions: ExtensionsView(store: store, details: details, onInstall: { installerName = "" })
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: 1000, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: store.phpVersion) { await store.loadPHP() }
        .task { await store.loadServices() }
        .sheet(
            isPresented: Binding(
                get: { installerName != nil && details != nil }, set: { if !$0 { installerName = nil } })
        ) {
            if let details { ExtensionInstaller(store: store, details: details, initialName: installerName ?? "") }
        }
        .confirmationDialog(
            "Use PHP \(version) in Terminal?", isPresented: $confirmingTerminal, titleVisibility: .visible
        ) {
            Button("Use PHP \(version)") { Task { _ = await store.useInTerminal(version) } }
        } message: {
            Text(
                "MacDev runs brew unlink for the current PHP and brew link --overwrite for PHP \(version), so the php, pecl and phpize commands in Homebrew’s bin folder switch versions. Sites keep their own PHP versions. A shell profile that adds another PHP to PATH still takes precedence."
            )
        }
        .confirmationDialog(
            "Stop \(stopping?.name ?? "PHP")?",
            isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
            titleVisibility: .visible
        ) {
            if let service = stopping {
                Button("Stop \(service.name)", role: .destructive) {
                    Task { await store.controlService(service, action: "stop") }
                }
            }
        } message: {
            Text("Sites using PHP \(version) stop responding until it is started again.")
        }
    }

    private var header: some View {
        let service = store.phpService(version: version)
        let siteCount = store.sites(usingPHP: version).count
        return HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("PHP \(version)").font(.title2.weight(.semibold))
                HStack(spacing: 14) {
                    if let service {
                        Label {
                            Text(service.statusTitle)
                        } icon: {
                            HealthDot(
                                health: service.isRunning
                                    ? .ok
                                    : service.hasError ? .problem(service.statusTitle) : .warning(service.statusTitle))
                        }
                        .help("Homebrew service \(service.name)")
                    }
                    if let release = details?.release {
                        Label(release, systemImage: "tag").help("Installed release")
                    }
                    if store.phpCLIVersion == version {
                        Label("Terminal default", systemImage: "terminal")
                            .help("Homebrew’s php command runs this version")
                    }
                    Label(siteCount == 1 ? "1 site" : "\(siteCount) sites", systemImage: "globe")
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let service {
                Button(service.isRunning ? "Restart" : "Start") {
                    Task { await store.controlService(service, action: service.isRunning ? "restart" : "start") }
                }
                .help(service.isRunning ? "Restart \(service.name)" : "Start \(service.name) and launch it at login")
            }
            Menu {
                Button("Use in Terminal…") { confirmingTerminal = true }
                    .disabled(store.phpCLIVersion == version)
                if let details {
                    Button("Show php.ini in Finder") { store.revealFile(details.iniPath) }
                }
                if let service {
                    Divider()
                    Button("Stop…", role: .destructive) { stopping = service }.disabled(!service.isRegistered)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 24)
            .help("More actions").accessibilityLabel("More actions for PHP \(version)")
        }
        .disabled(store.isBusy || store.isLoadingServices)
    }
}

private struct PHPOverview: View {
    @ObservedObject var store: SiteStore
    let details: PHPDetails
    let onInstall: (String) -> Void
    let onUseInTerminal: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("Runtime") { runtime }
                section("Development") { development }
                section("Sites on PHP \(details.version)") { sites }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(store.isBusy || store.isLoadingPHP)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            WorkspacePanel { content() }
        }
    }

    private var divider: some View { Divider().padding(.horizontal, 16) }

    @ViewBuilder private var runtime: some View {
        DetailRow("Terminal") {
            if store.phpCLIVersion == details.version {
                Label("Default php command", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text(store.phpCLIVersion.map { "Terminal uses PHP \($0)" } ?? "No Homebrew php command is linked")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if store.phpCLIVersion != details.version {
                Button("Use in Terminal…", action: onUseInTerminal)
                    .help("Link PHP \(details.version) as Homebrew’s php command")
            }
            ContextHelp(
                "Homebrew links one PHP version as the php command in its bin folder. Each site still uses the version chosen for it. A PHP path set in your shell profile takes precedence."
            )
        }
        if let listen = details.fpmListen {
            divider
            DetailRow("FPM address") {
                PathText(value: listen)
                Spacer(minLength: 0)
                ContextHelp(
                    "nginx connects to this address for sites on PHP \(details.version) (from php-fpm.d/www.conf).")
            }
        }
        if let binary = details.binary {
            divider
            DetailRow("Executable") {
                PathText(value: binary)
                Spacer(minLength: 0)
                Button("Copy") { store.copyToPasteboard(binary, label: "PHP \(details.version) path") }
                    .help("Copy the path, for example to configure an editor or IDE")
            }
        }
        divider
        DetailRow("php.ini") {
            PathText(value: details.iniPath)
            Spacer(minLength: 0)
            Button("Show in Finder") { store.revealFile(details.iniPath) }
        }
    }

    @ViewBuilder private var development: some View {
        let settings = details.settings
        let xdebug = details.extensions.first { $0.id == "xdebug" }
        DetailRow("Xdebug") {
            if let xdebug {
                Text(xdebugStatus(xdebug, mode: settings["xdebug.mode"]))
                    .foregroundStyle(xdebug.enabled && !xdebug.loaded ? .orange : .primary)
            } else {
                Text("Not installed").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let xdebug, xdebug.canToggle {
                Button(xdebug.enabled ? "Turn Off" : "Turn On") {
                    Task {
                        _ = await store.manageExtension(
                            details, name: xdebug.id, action: xdebug.enabled ? "disable" : "enable")
                    }
                }
            } else if xdebug == nil {
                Button("Install…") { onInstall("xdebug") }
                    .disabled(!details.installerAvailable)
                    .help(
                        details.installerAvailable ? "Install Xdebug with PECL" : "PECL is not available for this PHP")
            }
            ContextHelp(
                "Step debugging and better error pages. Xdebug slows every request while it is on, so turn it off when you are not debugging. Choose its mode on the Settings tab."
            )
        }
        divider
        let opcache = details.extensions.first { $0.id == "opcache" }
        let opcacheOn = phpFlag(settings["opcache.enable"]) && opcache?.isActive == true
        let checksFiles = phpFlag(settings["opcache.validate_timestamps"])
        DetailRow("OPcache") {
            if opcache?.isActive != true {
                Text("Not loaded").foregroundStyle(.secondary)
            } else if !opcacheOn {
                Text("Off")
            } else if checksFiles {
                Text("On · checks for changed files every \(settings["opcache.revalidate_freq"] ?? "2") s")
            } else {
                Label("On · ignores file changes until PHP restarts", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            if opcache?.isActive == true {
                if opcacheOn && !checksFiles {
                    Button("Check for Changes") { save(["opcache.validate_timestamps": "1"]) }
                        .help("Let OPcache notice edited files without a restart")
                }
                Button(opcacheOn ? "Turn Off" : "Turn On") { save(["opcache.enable": opcacheOn ? "0" : "1"]) }
            }
            ContextHelp(
                "Caches compiled scripts so pages load faster. For development, keep file checks on so edits show up without restarting PHP."
            )
        }
        divider
        let displaysErrors = phpFlag(settings["display_errors"])
        DetailRow("Errors") {
            Text(displaysErrors ? "Shown in pages" : "Hidden from pages")
            Spacer(minLength: 0)
            Button(displaysErrors ? "Hide" : "Show") { save(["display_errors": displaysErrors ? "Off" : "On"]) }
            ContextHelp(
                "Whether PHP prints errors into responses. Frameworks with their own error pages may override this. Set the reporting level on the Settings tab."
            )
        }
    }

    @ViewBuilder private var sites: some View {
        let sites = store.sites(usingPHP: details.version)
        if sites.isEmpty {
            Text("No sites use PHP \(details.version). Choose it for a site on the Sites page.")
                .foregroundStyle(.secondary).padding(16)
        }
        ForEach(Array(sites.enumerated()), id: \.element.id) { index, site in
            if index > 0 { divider }
            Button {
                store.selection = site.id
            } label: {
                HStack(spacing: 12) {
                    if let health = store.health(of: site) { HealthDot(health: health).help(health.message) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(site.domain).fontWeight(.medium)
                        Text(site.stackTitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if site.supports(phpVersion: details.version) == false, let requirement = site.phpRequirement {
                        Label("Requires PHP \(requirement)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show \(site.domain)")
        }
    }

    private func xdebugStatus(_ item: PHPExtension, mode: String?) -> String {
        if !item.enabled { return "Installed · Off" }
        if !item.loaded { return "Enabled but not loaded" }
        let mode = (mode ?? "").isEmpty ? "develop" : mode ?? ""
        return "On · mode \(mode)" + (item.version.map { " · \($0)" } ?? "")
    }

    private func save(_ values: [String: String]) {
        Task { _ = await store.savePHP(details, values: values) }
    }
}

private struct PHPSettingField: Identifiable {
    struct TextInput {
        let prompt: String
        let unit: String?
    }

    struct FlagValues {
        let onValue: String
        let offValue: String
    }

    enum Kind {
        case textInput(TextInput)
        case flag(FlagValues)
        case choice([(value: String, title: String)])
        case timeZone
        case xdebugModes

        static func text(prompt: String, unit: String? = nil) -> Self {
            .textInput(TextInput(prompt: prompt, unit: unit))
        }
        static func toggle(onValue: String, offValue: String) -> Self {
            .flag(FlagValues(onValue: onValue, offValue: offValue))
        }
    }

    let key: String
    let title: String
    let kind: Kind
    var help: String?
    var id: String { key }
}

private struct PHPSettingGroup: Identifiable {
    let title: String
    let fields: [PHPSettingField]
    var id: String { title }

    static func all(for details: PHPDetails) -> [Self] {
        var groups = [
            Self(
                title: "Resources",
                fields: [
                    .init(
                        key: "memory_limit", title: "Memory limit", kind: .text(prompt: "512M"), help: "-1 is unlimited"
                    ),
                    .init(
                        key: "max_execution_time", title: "Execution timeout",
                        kind: .text(prompt: "30", unit: "seconds"), help: "0 is unlimited"),
                    .init(
                        key: "max_input_time", title: "Input parsing timeout",
                        kind: .text(prompt: "-1", unit: "seconds"), help: "-1 uses the execution timeout"),
                    .init(key: "max_input_vars", title: "Maximum input variables", kind: .text(prompt: "1000")),
                ]),
            Self(
                title: "Uploads",
                fields: [
                    .init(key: "upload_max_filesize", title: "Maximum upload size", kind: .text(prompt: "64M")),
                    .init(
                        key: "post_max_size", title: "Maximum POST size", kind: .text(prompt: "64M"),
                        help: "At least the upload size; 0 is unlimited"),
                    .init(key: "max_file_uploads", title: "Files per request", kind: .text(prompt: "20")),
                ]),
            Self(
                title: "Errors",
                fields: [
                    .init(
                        key: "display_errors", title: "Display errors", kind: .toggle(onValue: "On", offValue: "Off")),
                    .init(
                        key: "display_startup_errors", title: "Display startup errors",
                        kind: .toggle(onValue: "On", offValue: "Off")),
                    .init(
                        key: "log_errors", title: "Log errors", kind: .toggle(onValue: "On", offValue: "Off"),
                        help: "Written to the site’s nginx error log unless error_log is set"),
                    .init(
                        key: "error_reporting", title: "Reporting level",
                        kind: .choice([
                            ("E_ALL", "All errors"),
                            ("E_ALL & ~E_DEPRECATED", "All except deprecations"),
                            ("E_ALL & ~E_DEPRECATED & ~E_NOTICE", "Errors and warnings"),
                            ("E_ERROR | E_PARSE", "Fatal errors only"),
                        ])),
                ]),
            Self(
                title: "Date and Time",
                fields: [.init(key: "date.timezone", title: "Default time zone", kind: .timeZone)]),
            Self(
                title: "OPcache",
                fields: [
                    .init(key: "opcache.enable", title: "Enable OPcache", kind: .toggle(onValue: "1", offValue: "0")),
                    .init(
                        key: "opcache.validate_timestamps", title: "Check for changed files",
                        kind: .toggle(onValue: "1", offValue: "0"), help: "Keep on while developing"),
                    .init(
                        key: "opcache.revalidate_freq", title: "Check interval",
                        kind: .text(prompt: "2", unit: "seconds"), help: "0 checks on every request"),
                    .init(
                        key: "opcache.memory_consumption", title: "Cache memory",
                        kind: .text(prompt: "128", unit: "MB")),
                ]),
        ]
        if details.extensions.contains(where: { $0.id == "xdebug" && $0.loaded }) {
            groups.append(
                Self(
                    title: "Xdebug",
                    fields: [
                        .init(key: "xdebug.mode", title: "Modes", kind: .xdebugModes),
                        .init(
                            key: "xdebug.start_with_request", title: "Start with request",
                            kind: .choice([
                                ("default", "Default for mode"), ("trigger", "With trigger"), ("yes", "Always"),
                                ("no", "Never"),
                            ]),
                            help: "Trigger means XDEBUG_TRIGGER, or a browser extension"),
                        .init(key: "xdebug.client_port", title: "Client port", kind: .text(prompt: "9003")),
                    ]))
        }
        return groups
    }
}

private struct PHPSettingsEditor: View {
    @ObservedObject var store: SiteStore
    let details: PHPDetails
    @State private var values: [String: String] = [:]

    private static let timeZones = ["UTC"] + TimeZone.knownTimeZoneIdentifiers.filter { $0 != "UTC" }.sorted()
    private static let xdebugModes = ["develop", "debug", "coverage", "profile", "trace"]

    /// Only edited settings are saved; every other value stays wherever it is configured now.
    private var changes: [String: String] {
        values.filter { (details.settings[$0.key] ?? "") != $0.value }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(PHPSettingGroup.all(for: details)) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.title).font(.headline)
                            WorkspacePanel {
                                ForEach(Array(group.fields.enumerated()), id: \.element.id) { index, field in
                                    if index > 0 { Divider().padding(.horizontal, 16) }
                                    row(field)
                                }
                            }
                        }
                    }
                    DisclosureGroup("Configuration files") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                PathText(value: details.scanDirectory + "/zzzz-macdev.ini")
                                Spacer()
                                Button("Show Folder in Finder") { store.revealFile(details.scanDirectory) }
                            }
                            Text(
                                "Changes are stored in MacDev’s INI file, loaded after \(details.iniPath). These are FPM defaults; pool or project settings may override them. The terminal may use a different php-cli.ini."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 12)
                    }
                    if let diagnostics = details.diagnostics {
                        Text(diagnostics).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                .padding(.bottom, 16)
            }
            Divider()
            HStack(spacing: 12) {
                ContextHelp(
                    "Size fields accept values such as 128M or 1G. Saving writes only the settings you changed, validates PHP, and restarts this version’s service if it is running."
                )
                Text(
                    changes.isEmpty
                        ? "Saving restarts PHP \(details.version) if it is running."
                        : changes.count == 1 ? "1 unsaved change" : "\(changes.count) unsaved changes"
                )
                .font(.caption).foregroundStyle(changes.isEmpty ? .secondary : .primary)
                Spacer()
                Button("Revert") { values = details.settings }
                    .disabled(changes.isEmpty)
                    .help("Discard unsaved changes")
                Button("Save Changes") { Task { _ = await store.savePHP(details, values: changes) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s")
                    .disabled(store.isBusy || store.isLoadingPHP || changes.isEmpty)
                    .help("Save and restart PHP \(details.version) if it is running (⌘S)")
            }
            .padding(.top, 12)
        }
        .onAppear { values = details.settings }
        .disabled(store.isBusy || store.isLoadingPHP)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func row(_ field: PHPSettingField) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(field.title)
                    if (values[field.key] ?? "") != (details.settings[field.key] ?? "") {
                        Text("Edited").font(.caption).foregroundStyle(.orange)
                            .accessibilityLabel("\(field.title) has unsaved changes")
                    }
                }
                if let help = field.help {
                    Text(help).font(.caption).foregroundStyle(.secondary)
                }
            }
            .help(field.key)
            Spacer(minLength: 20)
            control(field)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    @ViewBuilder private func control(_ field: PHPSettingField) -> some View {
        let value = binding(field.key)
        switch field.kind {
        case .textInput(let input):
            HStack(spacing: 6) {
                TextField(field.title, text: value, prompt: Text(input.prompt))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 120)
                    .multilineTextAlignment(.trailing)
                if let unit = input.unit {
                    Text(unit).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                }
            }
        case .flag(let flag):
            Toggle(
                field.title,
                isOn: Binding(
                    get: { phpFlag(value.wrappedValue) },
                    set: { value.wrappedValue = $0 ? flag.onValue : flag.offValue })
            )
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
        case .choice(let options):
            Picker(field.title, selection: value) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
                if !options.contains(where: { $0.value == value.wrappedValue }) {
                    Divider()
                    Text(value.wrappedValue.isEmpty ? "PHP default" : value.wrappedValue).tag(value.wrappedValue)
                }
            }
            .labelsHidden().fixedSize()
        case .timeZone:
            Picker(field.title, selection: value) {
                if !Self.timeZones.contains(value.wrappedValue) {
                    Text(value.wrappedValue.isEmpty ? "Not set" : value.wrappedValue).tag(value.wrappedValue)
                    Divider()
                }
                ForEach(Self.timeZones, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 220)
        case .xdebugModes:
            let selected = Set(value.wrappedValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            HStack(spacing: 4) {
                ForEach(Self.xdebugModes, id: \.self) { mode in
                    Toggle(
                        mode,
                        isOn: Binding(
                            get: { selected.contains(mode) },
                            set: { isOn in
                                let modes = Self.xdebugModes.filter { $0 == mode ? isOn : selected.contains($0) }
                                value.wrappedValue = modes.isEmpty ? "off" : modes.joined(separator: ",")
                            })
                    )
                    .toggleStyle(.button).controlSize(.small)
                }
            }
            .help("No modes selected turns Xdebug’s features off while keeping it loaded")
        }
    }
}

private struct ExtensionsView: View {
    @ObservedObject var store: SiteStore
    let details: PHPDetails
    let onInstall: () -> Void
    @State private var search = ""
    @State private var removing: PHPExtension?

    private var extensions: [PHPExtension] {
        details.extensions.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField(
                    "Find an extension", text: $search, prompt: Text("Filter \(details.extensions.count) extensions")
                )
                .textFieldStyle(.roundedBorder)
                Button("Install Extension…", action: onInstall)
                    .disabled(store.isBusy || store.isLoadingPHP || !details.installerAvailable)
                    .help(
                        details.installerAvailable
                            ? "Install a PECL package for PHP \(details.version)"
                            : "PECL is not available for PHP \(details.version), so extensions cannot be installed here"
                    )
            }
            List(extensions) { item in
                HStack {
                    extensionStatusIcon(item)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).fontWeight(.medium)
                        Text(
                            item.builtin
                                ? "Built into PHP"
                                : (item.enabled ? (item.loaded ? "Enabled" : "Enabled · Not loaded") : "Disabled")
                                    + (item.version.map { " · \($0)" } ?? "")
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.canSeparateIni == true {
                        Button("Move to Own INI") {
                            Task { _ = await store.manageExtension(details, name: item.id, action: "separate-ini") }
                        }
                        .help("Move the load directive to its own INI file, keeping the extension’s enabled state")
                    } else if let path = item.iniPath, !item.builtin {
                        Button {
                            store.revealFile(path)
                        } label: {
                            Image(systemName: "doc.text")
                        }
                        .help("Show extension INI in Finder").accessibilityLabel("Show extension INI in Finder")
                    }
                    if item.canToggle {
                        Button(item.enabled ? "Disable" : "Enable") {
                            Task {
                                _ = await store.manageExtension(
                                    details, name: item.id, action: item.enabled ? "disable" : "enable")
                            }
                        }
                    }
                    if item.canRemove {
                        Button("Remove…", role: .destructive) { removing = item }
                    }
                }.padding(.vertical, 5).disabled(store.isBusy || store.isLoadingPHP)
            }
            .listStyle(.inset)
            .overlay {
                if details.extensions.isEmpty {
                    ContentUnavailableView("No extensions found", systemImage: "puzzlepiece.extension")
                } else if extensions.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            HStack(spacing: 8) {
                ContextHelp(
                    "New installations use a separate INI file per extension. Use Move to Own INI to move existing load directives out of php.ini and consolidate duplicates. Built-in modules cannot be removed; only PECL packages can be uninstalled here."
                )
                Text(
                    "Built-in modules and extensions from other managers are kept separate from removable PECL packages."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            "Remove \(removing?.package ?? removing?.name ?? "extension") from PHP \(details.version)?",
            isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }
            ), titleVisibility: .visible
        ) {
            if let extensionToRemove = removing {
                Button("Remove Extension", role: .destructive) {
                    Task { _ = await store.manageExtension(details, name: extensionToRemove.id, action: "remove") }
                }
            }
        } message: {
            Text(
                "The extension will be disabled, then uninstalled using this PHP version’s PECL registry. Sites that depend on it may stop working."
            )
        }
    }
}

@ViewBuilder private func extensionStatusIcon(_ item: PHPExtension) -> some View {
    let (symbol, color, label): (String, Color, String) =
        if item.builtin {
            ("shippingbox", .secondary, "Built in")
        } else if item.enabled && item.loaded {
            ("checkmark.circle.fill", .green, "Enabled")
        } else if item.enabled {
            ("exclamationmark.triangle.fill", .orange, "Enabled but not loaded")
        } else {
            ("circle", .secondary, "Disabled")
        }
    Image(systemName: symbol).foregroundStyle(color).frame(width: 18).help(label).accessibilityLabel(label)
}

private struct ExtensionInstaller: View {
    @ObservedObject var store: SiteStore
    let details: PHPDetails
    var initialName = ""
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Install Extension for PHP \(details.version)").font(.title2.weight(.semibold))
            TextField("PECL package name", text: $name, prompt: Text("redis, xdebug, imagick…"))
                .textFieldStyle(.roundedBorder).disabled(store.isBusy)
            Text(
                "Downloads and builds the package using this PHP version’s tools, then enables each module in its own INI file. Build tools and required system libraries must already be installed. Installation can take several minutes."
            )
            .font(.callout).foregroundStyle(.secondary)
            if let error = store.error {
                ScrollView { Text(error).foregroundStyle(.red).textSelection(.enabled) }.frame(maxHeight: 150)
            }
            HStack {
                if store.isBusy {
                    ProgressView().controlSize(.small)
                    Text("Installing…").font(.caption)
                }
                Spacer()
                Button("Cancel") { dismiss() }.disabled(store.isBusy).keyboardShortcut(.cancelAction)
                Button("Install") {
                    Task {
                        if await store.manageExtension(
                            details, name: name.trimmingCharacters(in: .whitespaces), action: "install")
                        {
                            dismiss()
                        }
                    }
                }
                .disabled(store.isBusy || name.isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 560)
        .interactiveDismissDisabled(store.isBusy)
        .onAppear {
            store.error = nil
            name = initialName
        }
    }
}
