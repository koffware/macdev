import AppKit
import MacDevCore
import SwiftUI

private enum WorkspaceSection: String, CaseIterable {
    case sites = "Sites"
    case php = "PHP"
    case services = "Services"
}

struct SitesView: View {
    private let sidebarWidth: CGFloat = 240
    @ObservedObject var store: SiteStore
    @State private var addingSite = false
    @State private var lastSiteID: String?
    @State private var serviceSelection: String? = "all"
    @State private var serviceSearch = ""

    private var section: WorkspaceSection {
        switch store.selection {
        case "section:php": .php
        case "section:services": .services
        default: .sites
        }
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
                    case .services: ServicesView(store: store, selection: serviceSelection)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let message = store.error ?? store.warning {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            store.error == nil ? "Completed with a warning" : "MacDev needs your attention",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .fontWeight(.medium)
                        ScrollView {
                            Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 90)
                    }
                    .font(.callout).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background)
                    .accessibilityElement(children: .combine)
                }
                Divider()
                HStack(spacing: 8) {
                    if store.isBusy || store.isLoadingPHP || store.isLoadingServices {
                        ProgressView().controlSize(.mini)
                    }
                    Text(store.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(store.status)
                    Spacer()
                    if let backup = store.lastBackupPath {
                        Button("Show Backup") { store.revealFile(backup) }.font(.caption)
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
                        ForEach(WorkspaceSection.allCases, id: \.self) { item in
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
                    .disabled(store.isBusy || store.isLoadingPHP || store.isLoadingServices)
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
    }

    @ViewBuilder private var sidebar: some View {
        switch section {
        case .sites:
            List(selection: $store.selection) {
                Section("Sites") {
                    ForEach(store.filteredSites) { site in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(site.domain).lineLimit(1).truncationMode(.middle)
                                Text(
                                    site.phpVersion.map { "PHP \($0)" } ?? (site.fpm == nil ? "Static" : "PHP unknown")
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: site.certificate == nil ? "globe" : "lock")
                        }
                        .tag(site.id)
                        .help(site.domain)
                    }
                    if !store.search.isEmpty && store.filteredSites.isEmpty {
                        Text("No matching sites").foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $store.search, placement: .sidebar, prompt: "Search sites")
        case .php:
            List(
                selection: Binding<String?>(
                    get: { store.phpVersion.isEmpty ? nil : store.phpVersion },
                    set: { if let version = $0 { store.phpVersion = version } }
                )
            ) {
                Section("PHP Versions") {
                    ForEach(store.phpVersions, id: \.self) { version in
                        Label("PHP \(version)", systemImage: "chevron.left.forwardslash.chevron.right")
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
                                Text(service.status).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: service.isRunning ? "checkmark.circle" : "circle")
                        }
                        .tag(service.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $serviceSearch, placement: .sidebar, prompt: "Search services")
        }
    }

    @ViewBuilder private var siteDetail: some View {
        if let site = store.selectedSite {
            SiteDetailView(store: store, site: site).id(site.id)
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
    @State private var chosenVersion = ""
    @State private var editingSite: Site?
    @State private var confirmingRemoval = false
    // Used only through its `$` binding, which the analyzer does not index.
    // swiftlint:disable:next unused_declaration
    @State private var showingConfiguration = true

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
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Project").font(.headline)
                    WorkspacePanel {
                        HStack(spacing: 14) {
                            Image(systemName: "folder").font(.title2).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Project folder").font(.caption).foregroundStyle(.secondary)
                                PathText(value: site.root ?? "No document root found")
                            }
                            Spacer(minLength: 0)
                            if let root = site.root {
                                Button {
                                    store.openFolder(root)
                                } label: {
                                    Label("Open in Finder", systemImage: "folder")
                                }
                                .help("Open project folder in Finder")
                            }
                        }.padding(16)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("PHP").font(.headline)
                    WorkspacePanel {
                        HStack(spacing: 14) {
                            Text("PHP version").frame(width: 110, alignment: .leading)
                            if site.canSwitchPHP && !store.phpVersions.isEmpty {
                                Picker("PHP version", selection: $chosenVersion) {
                                    Text("Choose version").tag("")
                                    ForEach(store.phpVersions, id: \.self) { Text("PHP \($0)").tag($0) }
                                }
                                .labelsHidden().frame(width: 155).disabled(store.isBusy)
                                Button("Apply") { Task { await store.switchPHP(site: site, version: chosenVersion) } }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(chosenVersion.isEmpty || chosenVersion == site.phpVersion || store.isBusy)
                            } else {
                                Text(
                                    site.phpVersion.map { "PHP \($0)" }
                                        ?? (site.fpm == nil ? "Not configured" : "Unknown"))
                            }
                            Spacer(minLength: 0)
                            ContextHelp(
                                "Changes this site’s FPM address and reloads nginx after a configuration check. The selected PHP service must already be running."
                            )
                        }.padding(16)
                        if let fpm = site.fpm {
                            Divider().padding(.horizontal, 16)
                            HStack(spacing: 14) {
                                Text("FPM address").frame(width: 110, alignment: .leading)
                                PathText(value: fpm)
                                Spacer(minLength: 0)
                                ContextHelp("nginx uses this address to connect to PHP-FPM for this site.")
                            }.padding(16)
                        }
                    }
                }
                DisclosureGroup(isExpanded: $showingConfiguration) {
                    WorkspacePanel {
                        configurationRow("nginx configuration", site.configPath)
                        if let certificate = site.certificate {
                            Divider().padding(.horizontal, 16)
                            configurationRow("Certificate", certificate)
                        }
                    }.padding(.top, 10)
                } label: {
                    Text("Configuration").font(.headline)
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
            Label(
                site.certificate == nil ? "HTTP site" : "SSL configured",
                systemImage: site.certificate == nil ? "globe" : "lock.fill"
            )
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                store.openSite(site)
            } label: {
                Label("Open Site", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent).disabled(site.url == nil)
            Button {
                editingSite = site
            } label: {
                Label("Edit Site", systemImage: "pencil")
            }
            .disabled(store.isBusy || site.canEdit != true)
            Menu {
                Button("Remove Site…", role: .destructive) { confirmingRemoval = true }
                    .disabled(store.isBusy || site.canDelete != true)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).fixedSize().frame(width: 28)
            .accessibilityLabel("More site actions")
        }.fixedSize()
    }

    private func configurationRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 14) {
            Text(title).font(.callout).frame(width: 140, alignment: .leading)
            PathText(value: value)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless).help("Copy \(title)").accessibilityLabel("Copy \(title)")
            Button {
                store.revealFile(value)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless).help("Show \(title) in Finder").accessibilityLabel("Show \(title) in Finder")
        }.padding(16)
    }
}
