import MacDevCore
import SwiftUI

struct SitesView: View {
    @ObservedObject var store: SiteStore
    @State private var addingSite = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(selection: $store.selection) {
                    Section("Manage") {
                        Label("PHP", systemImage: "chevron.left.forwardslash.chevron.right").tag("section:php")
                        Label("Services", systemImage: "server.rack").tag("section:services")
                    }
                    Section("Sites · \(store.filteredSites.count)") {
                        ForEach(store.filteredSites) { site in
                            HStack(spacing: 12) {
                                Image(systemName: "globe")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(site.domain).fontWeight(.medium)
                                    Text(site.phpVersion.map { "PHP \($0)" } ?? (site.fpm == nil ? "Static site" : "PHP version unknown"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 5)
                            }
                            .tag(site.id)
                        }
                    }
                }
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
                .searchable(text: $store.search, prompt: "Find a site")
                .navigationTitle("MacDev")
            } detail: {
                if store.selection == "section:php" {
                    PHPView(store: store)
                } else if store.selection == "section:services" {
                    ServicesView(store: store)
                } else if let site = store.selectedSite {
                    SiteDetailView(store: store, site: site)
                        .id(site.id)
                } else if !store.hasLoaded {
                    ContentUnavailableView {
                        Label(store.isBusy ? "Loading your sites" : "Connect to MacDev", systemImage: "server.rack")
                    } description: {
                        Text(store.isBusy ? "Reading your Homebrew and nginx configuration." : "Check the Python interpreter in Settings, then refresh.")
                    } actions: {
                        SettingsLink { Text("Open Settings") }
                    }
                } else if store.sites.isEmpty {
                    ContentUnavailableView {
                        Label("No sites yet", systemImage: "globe")
                    } description: {
                        Text("Add a project folder and a local domain to create your first site.")
                    } actions: {
                        Button("Add Site") { addingSite = true }.disabled(store.isBusy)
                    }
                } else {
                    ContentUnavailableView("Select a site", systemImage: "sidebar.left", description: Text("Choose a site to see its details."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { addingSite = true } label: { Label("Add Site", systemImage: "plus") }
                        .disabled(store.isBusy || !store.hasLoaded || store.phpVersions.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await store.refresh() } } label: {
                        Label("Refresh Sites", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isBusy || store.isLoadingPHP || store.isLoadingServices)
                    .help("Reload sites and installed PHP versions")
                }
            }
            if let message = store.error ?? store.warning {
                VStack(alignment: .leading, spacing: 6) {
                    Label(store.error == nil ? "Completed with a warning" : "MacDev needs your attention", systemImage: "exclamationmark.triangle.fill")
                        .fontWeight(.medium)
                    ScrollView { Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 90)
                }
                .font(.callout)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.10))
                .accessibilityElement(children: .combine)
            }
            Divider()
            HStack(spacing: 8) {
                if store.isBusy { ProgressView().controlSize(.small) }
                Text(store.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let backup = store.lastBackupPath {
                    Button("Show Backup") { store.revealFile(backup) }.font(.caption)
                }
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .sheet(isPresented: $addingSite) { SiteEditor(store: store, site: nil) }
    }
}

private struct SiteDetailView: View {
    @ObservedObject var store: SiteStore
    let site: Site
    @State private var chosenVersion = ""
    @State private var editingSite: Site?
    @State private var confirmingRemoval = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(site.domain).font(.largeTitle.weight(.semibold)).textSelection(.enabled)
                        Label(site.certificate == nil ? "HTTP site" : "SSL configured",
                              systemImage: site.certificate == nil ? "globe" : "lock")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { store.openSite(site) } label: {
                        Label("Open Site", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(site.url == nil)
                }

                HStack {
                    Button("Edit Site…") { editingSite = site }
                        .disabled(store.isBusy || site.canEdit != true)
                    Spacer()
                    Button("Remove Site…", role: .destructive) { confirmingRemoval = true }
                        .disabled(store.isBusy || site.canDelete != true)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(site.root ?? "No document root found")
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let root = site.root {
                            Button { store.openFolder(root) } label: { Label("Open in Finder", systemImage: "folder") }
                        }
                    }.padding(10)
                } label: { Label("Project folder", systemImage: "folder") }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        LabeledContent("Current version", value: site.phpVersion.map { "PHP \($0)" }
                                       ?? (site.fpm == nil ? "Not configured" : "Unknown"))
                        if let fpm = site.fpm {
                            LabeledContent("FPM address") {
                                Text(fpm).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                        if site.canSwitchPHP && !store.phpVersions.isEmpty {
                            Divider()
                            HStack {
                                Picker("PHP version", selection: $chosenVersion) {
                                    Text("Choose version").tag("")
                                    ForEach(store.phpVersions, id: \.self) { version in
                                        Text("PHP \(version)").tag(version)
                                    }
                                }
                                .frame(maxWidth: 270)
                                Spacer()
                                Button("Apply") {
                                    Task { await store.switchPHP(site: site, version: chosenVersion) }
                                }
                                .disabled(chosenVersion.isEmpty || chosenVersion == site.phpVersion || store.isBusy)
                            }
                            .disabled(store.isBusy)
                            Text("Changes this site’s FPM address and reloads nginx after a configuration check. The selected PHP service must already be running.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10).frame(maxWidth: .infinity)
                } label: { Label("PHP", systemImage: "chevron.left.forwardslash.chevron.right") }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        detail("nginx configuration", site.configPath)
                        if let certificate = site.certificate { detail("Certificate", certificate) }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                } label: { Label("Configuration", systemImage: "doc.text") }
            }
            .padding(30)
            .frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity)
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
            Text("The nginx configuration will be backed up, then removed. Project files and certificates are kept. nginx will reload.")
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        }
    }
}
