import AppKit
import MacDevCore
import SwiftUI

private enum WorkspaceSection: String, CaseIterable {
    case sites = "Sites"
    case php = "PHP"
    case services = "Services"
    case docker = "Docker"
}

struct SitesView: View {
    private let sidebarWidth: CGFloat = 240
    @ObservedObject var store: SiteStore
    @State private var addingSite = false
    @State private var lastSiteID: String?
    @State private var serviceSelection: String? = "all"
    @State private var serviceSearch = ""
    @State private var dockerSelection: String? = DockerSelection.overview
    @State private var groupPrompt: GroupPrompt?
    @State private var groupName = ""

    private var section: WorkspaceSection {
        switch store.selection {
        case "section:php": .php
        case "section:services": .services
        case "section:docker": .docker
        default: .sites
        }
    }

    /// Docker appears only when a docker CLI is installed.
    private var sections: [WorkspaceSection] {
        WorkspaceSection.allCases.filter { $0 != .docker || store.dockerInstalled || section == .docker }
    }

    private var canAddSite: Bool {
        !store.isBusy && store.hasLoaded && !store.phpVersions.isEmpty
    }

    private var workspaceSelection: Binding<WorkspaceSection> {
        Binding(
            get: { section },
            set: { destination in
                guard destination != section else { return }
                if section == .sites { lastSiteID = store.selection }
                switch destination {
                case .sites:
                    store.selection = store.sites.first { $0.id == lastSiteID }?.id ?? store.sites.first?.id
                case .php: store.selection = "section:php"
                case .services: store.selection = "section:services"
                case .docker: store.selection = "section:docker"
                }
            })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .frame(width: sidebarWidth)
                .navigationSplitViewColumnWidth(min: sidebarWidth, ideal: sidebarWidth, max: sidebarWidth)
                .background(SidebarWidthLock(width: sidebarWidth))
                .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch section {
                    case .sites: siteDetail
                    case .php: PHPView(store: store)
                    case .services:
                        ServicesView(store: store, selection: serviceSelection) { serviceSelection = $0 }
                    case .docker:
                        DockerView(store: store, selection: dockerSelection) { dockerSelection = $0 }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let message = store.error ?? store.warning {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(
                                store.error == nil ? "Completed with a warning" : "MacDev needs your attention",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .fontWeight(.medium)
                            .foregroundStyle(store.error == nil ? Color.orange : Color.red)
                            Spacer()
                            Button {
                                store.dismissMessages()
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless).help("Dismiss").accessibilityLabel("Dismiss message")
                        }
                        ScrollView {
                            Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 90)
                    }
                    .font(.callout).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background)
                    .accessibilityElement(children: .contain)
                }
                Divider()
                HStack(spacing: 8) {
                    if store.isBusy || store.isLoadingPHP || store.isLoadingServices || store.isLoadingDocker {
                        ProgressView().controlSize(.mini)
                    }
                    Text(store.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(store.status)
                    Spacer()
                    if let backup = store.lastBackupPath {
                        Button("Show Backup") { store.revealFile(backup) }.font(.caption)
                            .help("Show the last removed site’s configuration backup in Finder")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(.bar)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .navigationTitle(section.rawValue)
            .workspaceToolbarTitleHidden()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Workspace", selection: workspaceSelection) {
                        ForEach(sections, id: \.self) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.extraLarge)
                    .fixedSize()
                }
                if section == .sites {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            addingSite = true
                        } label: {
                            Label("Add Site", systemImage: "plus")
                        }
                        .disabled(!canAddSite).help("Add Site (⌘N)")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await store.refreshCurrentSection() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isBusy || store.isLoadingPHP || store.isLoadingServices || store.isLoadingDocker)
                    .help("Refresh \(section.rawValue) (⌘R)")
                }
                ToolbarItem(placement: .automatic) {
                    SettingsLink { Label("Settings", systemImage: "gearshape") }.help("Settings")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar(removing: .sidebarToggle)
        .focusedSceneValue(\.addSite, canAddSite ? { addingSite = true } : nil)
        .sheet(isPresented: $addingSite) { SiteEditor(store: store, site: nil) }
        .alert(
            groupPrompt?.title ?? "",
            isPresented: Binding(get: { groupPrompt != nil }, set: { if !$0 { groupPrompt = nil } })
        ) {
            TextField("Group name", text: $groupName)
            Button(groupPrompt?.confirmTitle ?? "OK") { commitGroupPrompt() }
                .disabled(!store.siteGroups.isAvailable(groupName, excluding: groupPrompt?.renamedID))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Groups only organise the sidebar. Sites and their nginx configuration are not changed.")
        }
    }

    /// "Running · 3 sites · Terminal", built from what has loaded so far.
    private func phpVersionCaption(_ version: String) -> String {
        let count = store.sites(usingPHP: version).count
        return [
            store.phpService(version: version)?.statusTitle,
            count == 1 ? "1 site" : "\(count) sites",
            store.phpCLIVersion == version ? "Terminal" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private func promptForGroup(_ prompt: GroupPrompt) {
        if case .rename(let id) = prompt {
            groupName = store.siteGroups.groups.first { $0.id == id }?.name ?? ""
        } else {
            groupName = ""
        }
        groupPrompt = prompt
    }

    private func commitGroupPrompt() {
        switch groupPrompt {
        case .create(let siteID): store.createGroup(named: groupName, containing: siteID)
        case .rename(let id): store.renameGroup(id, to: groupName)
        case nil: break
        }
        groupPrompt = nil
    }

    @ViewBuilder private var sidebar: some View {
        switch section {
        case .sites:
            SiteSidebar(store: store, model: store.sidebarModel) { promptForGroup($0) }
                .overlay {
                    if !store.search.isEmpty && store.filteredSites.isEmpty {
                        ContentUnavailableView.search(text: store.search)
                    }
                }
                .searchable(text: $store.search, placement: .sidebar, prompt: "Search sites")
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    HStack {
                        Button {
                            promptForGroup(.create(siteID: nil))
                        } label: {
                            Label("New Group", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!store.hasLoaded)
                        .help("Create a group to organise your sites")
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                }
        case .php:
            List(
                selection: Binding<String?>(
                    get: { store.phpVersion.isEmpty ? nil : store.phpVersion },
                    set: { if let version = $0 { store.phpVersion = version } }
                )
            ) {
                Section("PHP Versions") {
                    ForEach(store.phpVersions, id: \.self) { version in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("PHP \(version)")
                                Text(phpVersionCaption(version)).font(.caption)
                                    .foregroundStyle(
                                        store.phpService(version: version)?.hasError == true ? .red : .secondary)
                            }
                        } icon: {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                        }
                        .tag(version)
                    }
                    if store.phpVersions.isEmpty {
                        Text("No installed versions").foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
            .disabled(store.isBusy)
        case .services:
            List(selection: $serviceSelection) {
                Section("Services") {
                    Label("All Services", systemImage: "server.rack").tag("all")
                    ForEach(
                        store.services.filter {
                            serviceSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(serviceSearch)
                        }
                    ) { service in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(service.name)
                                Text(
                                    [service.statusTitle, store.usageSummary(of: service)].compactMap { $0 }
                                        .joined(separator: " · ")
                                )
                                .font(.caption).lineLimit(1)
                                .foregroundStyle(service.hasError ? Color.red : Color.secondary)
                            }
                        } icon: {
                            Image(
                                systemName: service.isRunning
                                    ? "checkmark.circle" : (service.hasError ? "exclamationmark.circle" : "circle"))
                        }
                        .tag(service.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $serviceSearch, placement: .sidebar, prompt: "Search services")
        case .docker:
            DockerSidebar(store: store, selection: $dockerSelection)
        }
    }

    @ViewBuilder private var siteDetail: some View {
        if let site = store.selectedSite {
            SiteDetailView(store: store, site: site) { promptForGroup(.create(siteID: site.id)) }.id(site.id)
        } else if !store.hasLoaded {
            ContentUnavailableView {
                Label(store.isBusy ? "Loading your sites" : "Connect to MacDev", systemImage: "server.rack")
            } description: {
                Text(
                    store.isBusy
                        ? "Reading your Homebrew and nginx configuration."
                        : "Check the Python interpreter in Settings, then refresh.")
            } actions: {
                SettingsLink { Text("Open Settings") }
            }
        } else if store.sites.isEmpty {
            ContentUnavailableView {
                Label("No sites yet", systemImage: "globe")
            } description: {
                Text("Add a project folder and a local domain to create your first site.")
            } actions: {
                Button("Add Site") { addingSite = true }.disabled(store.isBusy || store.phpVersions.isEmpty)
            }
        } else {
            ContentUnavailableView(
                "Select a site", systemImage: "sidebar.left", description: Text("Choose a site to see its details."))
        }
    }
}

private struct SiteDetailView: View {
    @ObservedObject var store: SiteStore
    let site: Site
    let onNewGroup: () -> Void
    @State private var chosenVersion = ""
    @State private var editingSite: Site?
    @State private var confirmingRemoval = false
    @State private var showingConfiguration = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 18) {
                        heading
                        Spacer(minLength: 12)
                        actions
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        heading
                        actions
                    }
                }
                if let service = stoppedPHPService { stoppedPHPBanner(service) }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Project").font(.headline)
                    WorkspacePanel {
                        detailRow("Framework") {
                            Label(frameworkTitle, systemImage: site.fpm == nil ? "doc.richtext" : "shippingbox")
                                .foregroundStyle(site.framework == nil ? .secondary : .primary)
                            Spacer(minLength: 0)
                            ContextHelp(
                                "Detected from the project’s composer.lock, or from framework files such as artisan or wp-includes when there is no lock file. MacDev only reads these files."
                            )
                        }
                        Divider().padding(.horizontal, 16)
                        detailRow("Project folder") {
                            PathText(value: site.projectRoot ?? site.root ?? "No document root configured")
                                .foregroundStyle(site.rootExists == false ? .red : .primary)
                            Spacer(minLength: 0)
                            if let folder = site.projectRoot {
                                Button {
                                    store.openFolder(folder)
                                } label: {
                                    Label("Open in Finder", systemImage: "folder")
                                }
                                .help("Open the project folder in Finder")
                            } else if site.rootExists == false, site.root != nil {
                                Text("Folder not found").font(.callout).foregroundStyle(.red)
                            }
                        }
                        if let root = site.root, site.projectRoot != nil, root != site.projectRoot {
                            Divider().padding(.horizontal, 16)
                            detailRow("Web root") {
                                PathText(value: root)
                                Spacer(minLength: 0)
                                ContextHelp("The folder nginx serves files from (its root directive).")
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("PHP").font(.headline)
                    WorkspacePanel {
                        detailRow("Version") {
                            if site.canSwitchPHP && !store.phpVersions.isEmpty {
                                Picker("PHP version", selection: $chosenVersion) {
                                    Text("Choose version").tag("")
                                    ForEach(store.phpVersions, id: \.self) { Text(versionTitle($0)).tag($0) }
                                }
                                .labelsHidden().frame(minWidth: 155).fixedSize().disabled(store.isBusy)
                                Button("Switch PHP") {
                                    Task { await store.switchPHP(site: site, version: chosenVersion) }
                                }
                                .disabled(chosenVersion.isEmpty || chosenVersion == site.phpVersion || store.isBusy)
                                .help(
                                    chosenVersion == site.phpVersion
                                        ? "This site already uses PHP \(chosenVersion)"
                                        : site.supports(phpVersion: chosenVersion) == false
                                            ? "The project’s composer.json does not allow PHP \(chosenVersion); switch anyway and reload nginx"
                                            : "Switch this site to PHP \(chosenVersion) and reload nginx")
                            } else {
                                Text(
                                    site.phpVersion.map { "PHP \($0)" }
                                        ?? (site.fpm == nil ? "Not used · static site" : "Unknown"))
                            }
                            Spacer(minLength: 0)
                            ContextHelp(
                                "Changes this site’s FPM address and reloads nginx after a configuration check. The selected PHP service must already be running."
                            )
                        }
                        requirementRow
                        if let service = store.phpService(for: site) {
                            Divider().padding(.horizontal, 16)
                            detailRow("Service") {
                                Label {
                                    Text("\(service.name) · \(service.statusTitle)")
                                } icon: {
                                    HealthDot(health: service.isRunning ? .ok : .warning(service.statusTitle))
                                }
                                Spacer(minLength: 0)
                                Button(service.isRunning ? "Restart" : "Start") {
                                    Task {
                                        await store.controlService(
                                            service, action: service.isRunning ? "restart" : "start")
                                    }
                                }
                                .disabled(store.isBusy)
                                .help(service.isRunning ? "Restart \(service.name)" : "Start \(service.name)")
                            }
                        }
                        if let fpm = site.fpm {
                            Divider().padding(.horizontal, 16)
                            detailRow("FPM address") {
                                PathText(value: fpm)
                                Spacer(minLength: 0)
                                ContextHelp("nginx uses this address to connect to PHP-FPM for this site.")
                            }
                        }
                    }
                }
                SiteServerSection(store: store, site: site)
                DisclosureGroup(isExpanded: $showingConfiguration) {
                    WorkspacePanel {
                        configurationRow("nginx configuration", site.configPath)
                        if let certificate = site.certificate {
                            Divider().padding(.horizontal, 16)
                            configurationRow("Certificate", certificate)
                        }
                        if let key = site.certificateKey {
                            Divider().padding(.horizontal, 16)
                            configurationRow("Certificate key", key)
                        }
                        ForEach(site.logs ?? []) { log in
                            Divider().padding(.horizontal, 16)
                            configurationRow(log.title, log.path)
                        }
                    }.padding(.top, 10)
                } label: {
                    // macOS only toggles a DisclosureGroup from its arrow; make the whole header clickable.
                    Button {
                        withAnimation { showingConfiguration.toggle() }
                    } label: {
                        Text("Configuration").font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(showingConfiguration ? "Hides file paths" : "Shows file paths")
                }
            }
            .padding(20)
            .frame(maxWidth: 1060, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { chosenVersion = site.phpVersion ?? "" }
        .onChange(of: site.phpVersion) { _, version in chosenVersion = version ?? "" }
        .onChange(of: store.phpVersions) { _, versions in
            if !versions.contains(chosenVersion) { chosenVersion = "" }
        }
        .sheet(item: $editingSite) { snapshot in SiteEditor(store: store, site: snapshot) }
        .confirmationDialog("Remove \(site.domain)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Site", role: .destructive) { Task { await store.deleteSite(site) } }
        } message: {
            Text(
                "The nginx configuration will be backed up, then removed. Project files and certificates are kept. nginx will reload."
            )
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(site.domain).font(.title2.weight(.semibold)).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle).help(site.domain)
            HStack(spacing: 14) {
                if let health = store.health(of: site) {
                    Label {
                        Text(health.message)
                    } icon: {
                        HealthDot(health: health)
                    }
                    .foregroundStyle(health == .ok ? .secondary : health.color)
                }
                Label(
                    site.isSecure ? "HTTPS" : "HTTP only",
                    systemImage: site.isSecure ? "lock.fill" : "lock.open"
                )
                .foregroundStyle(.secondary)
                .help(site.isSecure ? "Served over HTTPS with a local certificate" : "No certificate configured")
                Label(site.summary, systemImage: "shippingbox").foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private var frameworkTitle: String {
        if site.framework != nil { return site.stackTitle }
        if site.fpm == nil { return "Static site" }
        return site.rootExists == false ? "Unknown · folder missing" : "Plain PHP · no framework detected"
    }

    private var stoppedPHPService: Service? {
        store.phpService(for: site).flatMap { $0.isRunning ? nil : $0 }
    }

    private func stoppedPHPBanner(_ service: Service) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("PHP \(site.phpVersion ?? "") is not running").fontWeight(.medium)
                Text("This site returns 502 Bad Gateway until \(service.name) is started.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Start PHP \(site.phpVersion ?? "")") {
                Task { await store.controlService(service, action: "start") }
            }
            .disabled(store.isBusy)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func detailRow(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        DetailRow(title, content: content)
    }

    @ViewBuilder private var requirementRow: some View {
        if let requirement = site.phpRequirement, site.fpm != nil {
            Divider().padding(.horizontal, 16)
            detailRow("Requires") {
                Label {
                    Text("PHP \(requirement)")
                } icon: {
                    switch site.requirementMet {
                    case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case false?: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    case nil: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    }
                }
                Text(requirementDetail).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                ContextHelp(
                    "The PHP versions this project’s composer.json allows (require.php). MacDev compares it with the installed versions; it never runs Composer."
                )
            }
        }
    }

    private var requirementDetail: String {
        guard let supported = site.phpSupportedVersions else { return "· MacDev could not read this constraint" }
        if site.requirementMet == true { return "· satisfied by PHP \(site.phpVersion ?? "")" }
        if supported.isEmpty { return "· no installed PHP version satisfies it" }
        return "· switch to PHP \(supported.joined(separator: ", "))"
    }

    private func versionTitle(_ version: String) -> String {
        site.supports(phpVersion: version) == false ? "PHP \(version) · not supported by project" : "PHP \(version)"
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                store.openSite(site)
            } label: {
                Label("Open Site", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent).disabled(site.url == nil)
            .help(
                site.url.map { "Open \($0.absoluteString) in your browser" }
                    ?? "This server name is a pattern, so it has no single address to open")
            Button {
                editingSite = site
            } label: {
                Label("Edit Site", systemImage: "pencil")
            }
            .disabled(store.isBusy || site.canEdit != true)
            .help(
                site.canEdit == true
                    ? "Change the domain, folder, PHP version, or certificate"
                    : "This configuration was not created by MacDev and can only be edited by hand")
            Menu {
                if let url = site.url {
                    Button("Copy Site Address") { store.copyToPasteboard(url.absoluteString, label: "site address") }
                }
                Button("Show nginx Configuration in Finder") { store.revealFile(site.configPath) }
                Divider()
                SiteGroupMenu(store: store, siteID: site.id, onNewGroup: onNewGroup)
                Divider()
                Button("Remove Site…", role: .destructive) { confirmingRemoval = true }
                    .disabled(store.isBusy || site.canDelete != true)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 28)
            .help("More actions").accessibilityLabel("More site actions")
        }.fixedSize()
    }

    private func configurationRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 14) {
            Text(title).font(.callout).frame(width: 140, alignment: .leading)
            PathText(value: value)
            Spacer(minLength: 0)
            Button {
                store.copyToPasteboard(value, label: "\(title.lowercased()) path")
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless).help("Copy \(title) Path").accessibilityLabel("Copy \(title) path")
            Button {
                store.revealFile(value)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless).help("Show \(title) in Finder").accessibilityLabel("Show \(title) in Finder")
        }.padding(16)
    }
}

struct HealthDot: View {
    let health: SiteHealth

    var body: some View {
        Circle().fill(health.color).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}

extension SiteHealth {
    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .problem: .red
        }
    }
}

enum GroupPrompt {
    case create(siteID: String?)
    case rename(UUID)

    var title: String {
        switch self {
        case .create: "New Group"
        case .rename: "Rename Group"
        }
    }

    var confirmTitle: String {
        switch self {
        case .create: "Create"
        case .rename: "Rename"
        }
    }

    var renamedID: UUID? {
        if case .rename(let id) = self { return id }
        return nil
    }
}

/// "Move to Group" and "Remove from Group" items, shared by the sidebar and the detail menu.
private struct SiteGroupMenu: View {
    @ObservedObject var store: SiteStore
    let siteID: String
    let onNewGroup: () -> Void

    var body: some View {
        let current = store.siteGroups.group(containing: siteID)
        Menu("Move to Group") {
            ForEach(store.siteGroups.groups) { group in
                Button(group.name) { store.moveSite(siteID, toGroup: group.id) }
                    .disabled(group.id == current?.id)
            }
            if !store.siteGroups.groups.isEmpty { Divider() }
            Button("New Group…", action: onNewGroup)
        }
        if let current {
            Button("Remove from “\(current.name)”") { store.moveSite(siteID, toGroup: nil) }
        }
    }
}
