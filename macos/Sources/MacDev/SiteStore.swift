import AppKit
import MacDevCore

@MainActor
final class SiteStore: ObservableObject {
    @Published private(set) var sites: [Site] = []
    @Published private(set) var phpVersions: [String] = []
    @Published private(set) var phpServices: [String: String] = [:]
    @Published private(set) var phpCLIVersion: String?
    @Published private(set) var siteGroups: SiteGroups {
        didSet {
            guard siteGroups != oldValue, let data = try? JSONEncoder().encode(siteGroups.groups) else { return }
            defaults.set(data, forKey: Self.groupsKey)
        }
    }
    @Published private(set) var isBusy = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var status = "Ready to load your sites"
    @Published var error: String?
    @Published private(set) var warning: String?
    @Published var selection: String?
    @Published var search = ""
    @Published var pythonExecutable: String
    @Published private(set) var services: [Service] = [] {
        // Lets service pages re-read their details whenever Homebrew status is read again.
        didSet { servicesRevision += 1 }
    }
    @Published private(set) var servicesRevision = 0
    @Published private(set) var servicesError: String?
    @Published private(set) var isLoadingServices = false
    @Published private(set) var dockerInstalled = false
    @Published private(set) var docker: DockerState?
    @Published private(set) var dockerError: String?
    @Published private(set) var isLoadingDocker = false
    /// Set while MacDev waits for a Docker app it opened to bring its engine up.
    @Published private(set) var isStartingDocker = false
    @Published private(set) var phpDetails: PHPDetails?
    @Published private(set) var phpError: String?
    @Published private(set) var isLoadingPHP = false
    @Published var phpVersion = "" {
        didSet {
            guard phpVersion != oldValue else { return }
            phpRequestID = UUID()
            isLoadingPHP = false
            phpDetails = nil
            phpError = nil
            if let cached = phpCache[phpVersion] { showPHP(cached) }
        }
    }
    @Published private(set) var lastBackupPath: String?
    @Published private(set) var isStarting = true
    @Published private(set) var startupStatus = "Reading sites and installed PHP versions…"

    private static let groupsKey = "siteGroups"
    private let defaults: UserDefaults
    private let sourceDirectory: URL
    private let backendOverride: Backend?
    private var phpRequestID = UUID()
    private var didPreload = false
    private var preloadGeneration = UUID()
    private var hasLoadedServices = false
    private var hasLoadedDocker = false
    // Published so site pages update when a version's settings finish loading.
    @Published private var phpCache: [String: Result<PHPDetails, Error>] = [:]
    private var phpLoads: [String: Task<Result<PHPDetails, Error>, Never>] = [:]

    init(backend: Backend? = nil, defaults: UserDefaults = .standard) {
        backendOverride = backend
        self.defaults = defaults
        siteGroups = SiteGroups(
            defaults.data(forKey: Self.groupsKey).flatMap { try? JSONDecoder().decode([SiteGroup].self, from: $0) }
                ?? [])
        let resourceDirectory = Bundle.main.resourceURL
        let configuration = resourceDirectory.flatMap {
            try? Data(contentsOf: $0.appendingPathComponent("Backend.json"))
        }
        .flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) }
        pythonExecutable =
            defaults.string(forKey: "pythonExecutable")
            ?? configuration?.pythonExecutable ?? "/opt/homebrew/bin/python3"
        let bundled = resourceDirectory?.appendingPathComponent("backend")
        if let bundled, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("macdev/api.py").path) {
            sourceDirectory = bundled
        } else {
            // Allows `swift run` from the development checkout.
            sourceDirectory = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("src")
        }
    }

    private struct Configuration: Decodable { let pythonExecutable: String }

    var selectedSite: Site? { sites.first { $0.id == selection } }
    var filteredSites: [Site] {
        sites.filter {
            search.isEmpty || $0.domain.localizedCaseInsensitiveContains(search)
                || ($0.root?.localizedCaseInsensitiveContains(search) ?? false)
                || $0.stackTitle.localizedCaseInsensitiveContains(search)
        }
    }

    var sidebarModel: SiteSidebarModel {
        let sections = siteGroups.sections(for: filteredSites, searching: !search.isEmpty)
        return SiteSidebarModel(
            groups: sections.map { section in
                SiteSidebarModel.Group(
                    id: section.group?.id, name: section.group?.name ?? "",
                    rows: section.sites.map { site in
                        SiteSidebarModel.Row(
                            id: site.id, domain: site.domain, summary: site.summary, isSecure: site.isSecure,
                            health: health(of: site))
                    })
            },
            collapsed: Set(siteGroups.groups.filter { !$0.isExpanded }.map(\.id)),
            searching: !search.isEmpty)
    }

    @discardableResult func createGroup(named name: String, containing siteID: String? = nil) -> UUID? {
        siteGroups.create(named: name, containing: siteID)
    }

    func renameGroup(_ id: UUID, to name: String) { siteGroups.rename(id, to: name) }
    func deleteGroup(_ id: UUID) { siteGroups.delete(id) }
    /// Ignores IDs that are not current sites, such as text dragged in from another app.
    func moveSite(_ siteID: String, toGroup groupID: UUID?, before anchor: String? = nil) {
        guard sites.contains(where: { $0.id == siteID }) else { return }
        siteGroups.move(siteID, to: groupID, before: anchor)
    }
    func shiftGroup(_ id: UUID, by offset: Int) { siteGroups.shift(id, by: offset) }
    func moveGroup(_ id: UUID, to index: Int) { siteGroups.moveGroup(id, to: index) }
    func setGroupExpanded(_ id: UUID, _ isExpanded: Bool) { siteGroups.setExpanded(id, isExpanded) }

    /// The Homebrew PHP-FPM service a site depends on, once service status is loaded.
    func phpService(for site: Site) -> Service? {
        guard site.fpm != nil, let version = site.phpVersion, let name = phpServices[version] else { return nil }
        return services.first { $0.name == name }
    }

    /// The Homebrew PHP-FPM service for a version, once service status is loaded.
    func phpService(version: String) -> Service? {
        guard let name = phpServices[version] else { return nil }
        return services.first { $0.name == name }
    }

    /// Sites that stop working without SERVICE: every site for nginx, the version's sites for
    /// PHP-FPM, and nil for services MacDev does not connect to sites.
    func sites(dependingOn service: Service) -> [Site]? {
        if service.name == "nginx" {
            return sites.sorted { $0.domain.localizedStandardCompare($1.domain) == .orderedAscending }
        }
        guard let version = phpServices.first(where: { $0.value == service.name })?.key else { return nil }
        return sites(usingPHP: version)
    }

    /// "Serves 9 sites", "Used by 1 site", or "No sites use PHP 8.3"; nil for other services.
    func usageSummary(of service: Service) -> String? {
        guard let dependents = sites(dependingOn: service) else { return nil }
        let count = dependents.count == 1 ? "1 site" : "\(dependents.count) sites"
        if service.name == "nginx" { return "Serves \(count)" }
        guard !dependents.isEmpty else {
            let version = phpServices.first { $0.value == service.name }?.key ?? ""
            return "No sites use PHP \(version)"
        }
        return "Used by \(count)"
    }

    func showSite(_ site: Site) {
        search = ""
        selection = site.id
    }

    func serviceDetails(_ service: Service) async -> Result<ServiceDetails, Error> {
        let backend = backend
        do { return .success(try await backend.serviceDetails(name: service.name)) } catch { return .failure(error) }
    }

    func readServiceLog(_ service: Service, kind: String) async -> Result<LogTail, Error> {
        let backend = backend
        do { return .success(try await backend.serviceLog(name: service.name, kind: kind)) } catch {
            return .failure(error)
        }
    }

    func checkService(_ service: Service) async -> Result<ServiceCheck, Error> {
        let backend = backend
        do { return .success(try await backend.checkService(name: service.name)) } catch { return .failure(error) }
    }

    func sites(usingPHP version: String) -> [Site] {
        sites.filter { $0.fpm != nil && $0.phpVersion == version }
            .sorted { $0.domain.localizedStandardCompare($1.domain) == .orderedAscending }
    }

    /// FPM defaults of the site's PHP version, once that version's details have loaded.
    func phpSettings(for site: Site) -> [String: String]? {
        guard site.fpm != nil, let version = site.phpVersion, case .success(let details) = phpCache[version] else {
            return nil
        }
        return details.settings
    }

    func readLog(_ site: Site, kind: String) async -> Result<LogTail, Error> {
        let backend = backend
        do { return .success(try await backend.siteLog(siteID: site.id, kind: kind)) } catch { return .failure(error) }
    }

    func health(of site: Site) -> SiteHealth? {
        site.health(services: services, phpService: site.phpVersion.flatMap { phpServices[$0] })
    }
    private var backend: Backend {
        backendOverride ?? Backend(pythonExecutable: pythonExecutable, sourceDirectory: sourceDirectory)
    }

    func preload() async {
        guard !didPreload else { return }
        didPreload = true
        let generation = UUID()
        preloadGeneration = generation
        isStarting = true
        startupStatus = "Reading sites and installed PHP versions…"
        defer { if preloadGeneration == generation { isStarting = false } }
        await refresh()
        guard hasLoaded else { return }
        async let serviceLoad: () = loadServices(force: true)
        if !phpVersion.isEmpty {
            startupStatus = "Loading PHP \(phpVersion) configuration and extensions…"
            await loadPHP()
        }
        startupStatus = "Reading service status…"
        await serviceLoad
        guard preloadGeneration == generation else { return }
        // The workspace is usable now; warm the remaining versions behind it.
        // Probes stay sequential: each one runs PHP and inspects its PECL registry.
        isStarting = false
        for version in phpVersions where phpCache[version] == nil {
            guard preloadGeneration == generation else { return }
            _ = await fetchPHP(version: version)
        }
    }

    func refreshCurrentSection() async {
        switch selection {
        case "section:php":
            async let services: () = loadServices(force: true)
            await loadPHP(force: true)
            await services
        case "section:services": await loadServices(force: true)
        case "section:docker": await loadDocker(force: true)
        default: await refresh()
        }
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        warning = nil
        status = "Loading sites…"
        defer { isBusy = false }
        do {
            try await loadSnapshot()
            status =
                "\(sites.count) \(sites.count == 1 ? "site" : "sites") · Updated \(Date.now.formatted(date: .omitted, time: .shortened))"
        } catch {
            self.error = error.localizedDescription
            status = hasLoaded ? "Could not refresh · Showing previously loaded sites" : "Could not connect to MacDev"
        }
    }

    private func loadSnapshot() async throws {
        let snapshot = try await backend.snapshot()
        sites = snapshot.sites
        phpVersions = snapshot.phpVersions
        phpServices = snapshot.phpServices ?? [:]
        phpCLIVersion = snapshot.phpCLIVersion
        dockerInstalled = snapshot.dockerInstalled ?? false
        phpCache = phpCache.filter { phpVersions.contains($0.key) }
        hasLoaded = true
        if selection?.hasPrefix("section:") != true && !sites.contains(where: { $0.id == selection }) {
            selection = sites.first?.id
        }
        if !phpVersions.contains(phpVersion) { phpVersion = phpVersions.first ?? "" }
    }

    func loadServices(force: Bool = false) async {
        guard !isLoadingServices else { return }
        guard force || !hasLoadedServices else { return }
        isLoadingServices = true
        servicesError = nil
        defer { isLoadingServices = false }
        do {
            services = try await backend.services().services
            hasLoadedServices = true
        } catch {
            // Leave the cache unloaded so the next visit retries automatically.
            servicesError = error.localizedDescription
        }
    }

    private func fetchPHP(version: String, force: Bool = false) async -> Result<PHPDetails, Error> {
        let task: Task<Result<PHPDetails, Error>, Never>
        if !force, let pending = phpLoads[version] {
            task = pending
        } else if !force, let cached = phpCache[version] {
            return cached
        } else {
            // A forced read never joins a pending one: that read may predate a
            // configuration change and would cache stale settings and revision.
            let backend = backend
            task = Task {
                do { return .success(try await backend.phpDetails(version: version)) } catch { return .failure(error) }
            }
            phpLoads[version] = task
        }
        let result = await task.value
        if phpLoads[version] == task {
            phpCache[version] = result
            phpLoads[version] = nil
            return result
        }
        // Superseded by a newer read: never let this one overwrite it.
        if phpLoads[version] != nil { return await fetchPHP(version: version) }
        return phpCache[version] ?? result
    }

    private func showPHP(_ result: Result<PHPDetails, Error>) {
        switch result {
        case .success(let details):
            phpDetails = details
            phpError = nil
        case .failure(let error): phpError = error.localizedDescription
        }
    }

    func loadPHP(force: Bool = false) async {
        let requestID = UUID()
        phpRequestID = requestID
        let version = phpVersion
        guard !version.isEmpty else {
            phpDetails = nil
            phpError = nil
            isLoadingPHP = false
            return
        }
        if !force, phpLoads[version] == nil, let cached = phpCache[version] {
            if phpDetails?.version != version { phpDetails = nil }
            showPHP(cached)
            isLoadingPHP = false
            return
        }
        isLoadingPHP = true
        phpError = nil
        if phpDetails?.version != version { phpDetails = nil }
        defer { if phpRequestID == requestID { isLoadingPHP = false } }
        let result = await fetchPHP(version: version, force: force)
        if phpRequestID == requestID { showPHP(result) }
    }

    private func perform(
        _ message: String, success: String,
        affectedPHPVersion: String? = nil,
        invalidatesServices: Bool = true,
        reloadsSites: Bool = true,
        action: () async throws -> Void
    ) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        error = nil
        warning = nil
        status = message
        defer { isBusy = false }
        var succeeded = false
        do {
            try await action()
            status = success
            succeeded = true
        } catch {
            self.error = error.localizedDescription
            status = "Operation failed"
        }
        if reloadsSites {
            do { try await loadSnapshot() } catch {
                self.error = [self.error, "Could not refresh: \(error.localizedDescription)"].compactMap { $0 }
                    .joined(separator: "\n")
            }
        }
        // Service status rarely changes here; re-read it when the page is next shown.
        if invalidatesServices { hasLoadedServices = false }
        if selection == "section:services" { await loadServices() }
        if let version = affectedPHPVersion {
            _ = await fetchPHP(version: version, force: true)
        }
        if selection == "section:php" { await loadPHP() }
        return succeeded
    }

    func saveSite(
        _ site: Site?, domain: String, root: String, version: String,
        certificate: String, key: String
    ) async -> Bool {
        await perform(site == nil ? "Creating site…" : "Saving site…", success: "Site saved") {
            let result = try await backend.saveSite(
                site: site, domain: domain, root: root,
                version: version, certificate: certificate, key: key)
            if let site, let newID = result.id, newID != site.id { siteGroups.replace(site.id, with: newID) }
            selection = result.id
            search = ""
        }
    }

    func deleteSite(_ site: Site) async {
        _ = await perform("Removing \(site.domain)…", success: "Site removed · Configuration backup kept") {
            let result = try await backend.deleteSite(site)
            lastBackupPath = result.backupPath
            siteGroups.move(site.id, to: nil)
        }
    }

    func controlService(_ service: Service, action: String) async {
        let succeeded = await perform(
            "\(action.capitalized) \(service.name)…", success: "\(service.name): \(action) completed",
            invalidatesServices: false
        ) {
            let result = try await backend.serviceAction(service, action: action)
            services = result.services
            servicesError = nil
            hasLoadedServices = true
            warning = result.warning
        }
        // A failed action may still have changed state; show what Homebrew reports.
        if !succeeded && !isBusy { await loadServices(force: true) }
    }

    // MARK: Docker

    func loadDocker(force: Bool = false) async {
        guard !isLoadingDocker, force || !hasLoadedDocker else { return }
        isLoadingDocker = true
        defer { isLoadingDocker = false }
        do {
            docker = try await backend.docker()
            dockerError = nil
            hasLoadedDocker = true
        } catch {
            // Leave the state unloaded so the next visit retries automatically.
            dockerError = error.localizedDescription
        }
    }

    func controlContainer(_ container: DockerContainer, action: String) async {
        await performDocker(
            "\(Self.progressTitle(action)) \(container.name)…", success: "\(container.name): \(action) completed"
        ) {
            try await backend.dockerContainerAction(id: container.id, action: action)
        }
    }

    func controlProject(_ project: DockerProject, action: String) async {
        await performDocker(
            "\(Self.progressTitle(action)) \(project.name)…", success: "\(project.name): \(action) completed"
        ) {
            try await backend.dockerProjectAction(name: project.name, action: action)
        }
    }

    func removeImage(_ image: DockerImage) async {
        await performDocker("Removing \(image.title)…", success: "Removed \(image.title)") {
            try await backend.removeDockerImage(id: image.id)
        }
    }

    func pruneImages() async {
        await performDocker("Removing dangling images…", success: "Dangling images removed") {
            try await backend.pruneDockerImages()
        }
    }

    func readContainerLog(_ container: DockerContainer) async -> Result<ContainerLog, Error> {
        let backend = backend
        do { return .success(try await backend.containerLog(id: container.id)) } catch { return .failure(error) }
    }

    /// Docker actions return the engine's new state, so sites and services are not re-read.
    private func performDocker(
        _ message: String, success: String, action: () async throws -> DockerState
    ) async {
        let succeeded = await perform(message, success: success, invalidatesServices: false, reloadsSites: false) {
            let state = try await action()
            docker = state
            dockerError = nil
            if let message = state.message { status = "\(success) · \(message)" }
        }
        // A failed action may still have changed state; show what Docker reports.
        if !succeeded && !isBusy { await loadDocker(force: true) }
    }

    private static func progressTitle(_ action: String) -> String {
        switch action {
        case "start": "Starting"
        case "stop": "Stopping"
        case "restart": "Restarting"
        case "remove": "Removing"
        default: action.capitalized
        }
    }

    /// The app that runs the Docker engine on this Mac, if one is installed.
    var dockerApp: (name: String, url: URL)? {
        let apps = [
            ("Docker Desktop", "com.docker.docker"), ("OrbStack", "dev.kdrag0n.MacVirt"),
            ("Rancher Desktop", "io.rancherdesktop.app"),
        ]
        for (name, identifier) in apps {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { return (name, url) }
        }
        return nil
    }

    /// Opens the Docker app, then re-reads the engine until it answers or about a minute passes.
    func startDockerEngine() async {
        guard let app = dockerApp, !isStartingDocker else { return }
        isStartingDocker = true
        defer { isStartingDocker = false }
        status = "Opening \(app.name)…"
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
        } catch {
            self.error = "Could not open \(app.name): \(error.localizedDescription)"
            return
        }
        status = "Waiting for the Docker engine…"
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(3))
            await loadDocker(force: true)
            if docker?.running == true {
                status = "Docker engine is running"
                return
            }
        }
        status = "The Docker engine has not started yet · Refresh to check again"
    }

    func savePHP(_ details: PHPDetails, values: [String: String]) async -> Bool {
        await perform(
            "Saving PHP \(details.version) settings…", success: "PHP settings saved",
            affectedPHPVersion: details.version
        ) {
            warning = try await backend.savePHPSettings(details, values: values).warning
        }
    }

    func useInTerminal(_ version: String) async -> Bool {
        await perform(
            "Linking PHP \(version) as the Terminal php…", success: "Terminal now uses PHP \(version)",
            invalidatesServices: false
        ) {
            warning = try await backend.useInTerminal(version: version).warning
        }
    }

    func manageExtension(_ details: PHPDetails, name: String, action: String) async -> Bool {
        await perform(
            "\(action.capitalized) \(name) for PHP \(details.version)…",
            success: "Extension \(action) completed", affectedPHPVersion: details.version
        ) {
            warning = try await backend.extensionAction(details, name: name, action: action).warning
        }
    }

    func dismissMessages() {
        error = nil
        warning = nil
    }

    func copyToPasteboard(_ value: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        status = "Copied \(label)"
    }

    func revealFile(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func switchPHP(site: Site, version: String) async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        warning = nil
        status = "Switching \(site.domain) to PHP \(version)…"
        defer { isBusy = false }
        do {
            let result = try await backend.switchPHP(siteID: site.id, version: version)
            status =
                result.changed ? "\(site.domain) now uses PHP \(version)" : "\(site.domain) already uses PHP \(version)"
        } catch {
            self.error = error.localizedDescription
            status = "PHP change failed"
        }
        // Refresh even on failure: disk state may have been restored by the backend.
        do { try await loadSnapshot() } catch {
            self.error = [self.error, "Could not refresh sites: \(error.localizedDescription)"].compactMap { $0 }
                .joined(separator: "\n")
        }
    }

    func saveInterpreter(_ path: String) async {
        guard !isBusy, !isStarting, !isLoadingPHP, !isLoadingServices else { return }
        pythonExecutable = path.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(pythonExecutable, forKey: "pythonExecutable")
        phpCache.removeAll()
        phpLoads.removeAll()
        phpRequestID = UUID()
        phpDetails = nil
        phpError = nil
        hasLoaded = false
        hasLoadedServices = false
        services = []
        hasLoadedDocker = false
        docker = nil
        dockerError = nil
        didPreload = false
        await preload()
    }

    func openSite(_ site: Site) {
        guard let url = site.url, NSWorkspace.shared.open(url) else {
            error = "Could not open this site's address."
            return
        }
    }

    func openURL(_ url: URL) {
        guard NSWorkspace.shared.open(url) else {
            error = "Could not open \(url.absoluteString)."
            return
        }
    }

    func openFile(_ path: String) {
        guard FileManager.default.fileExists(atPath: path), NSWorkspace.shared.open(URL(fileURLWithPath: path)) else {
            error = "This file could not be opened: \(path)"
            return
        }
    }

    func openFolder(_ path: String) {
        guard FileManager.default.fileExists(atPath: path), NSWorkspace.shared.open(URL(fileURLWithPath: path)) else {
            error = "This folder could not be opened: \(path)"
            return
        }
    }
}
