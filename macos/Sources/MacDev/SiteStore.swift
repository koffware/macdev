import AppKit
import MacDevCore
import SwiftUI

@MainActor
final class SiteStore: ObservableObject {
    @Published private(set) var sites: [Site] = []
    @Published private(set) var phpVersions: [String] = []
    @Published private(set) var isBusy = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var status = "Ready to load your sites"
    @Published var error: String?
    @Published private(set) var warning: String?
    @Published var selection: String?
    @Published var search = ""
    @Published var pythonExecutable: String
    @Published private(set) var services: [Service] = []
    @Published private(set) var servicesError: String?
    @Published private(set) var isLoadingServices = false
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

    private let sourceDirectory: URL
    private let backendOverride: Backend?
    private var phpRequestID = UUID()
    private var didPreload = false
    private var preloadGeneration = UUID()
    private var hasLoadedServices = false
    private var phpCache: [String: Result<PHPDetails, Error>] = [:]
    private var phpLoads: [String: Task<Result<PHPDetails, Error>, Never>] = [:]

    init(backend: Backend? = nil) {
        backendOverride = backend
        let resourceDirectory = Bundle.main.resourceURL
        let configuration = resourceDirectory.flatMap { try? Data(contentsOf: $0.appendingPathComponent("Backend.json")) }
            .flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) }
        pythonExecutable = UserDefaults.standard.string(forKey: "pythonExecutable")
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
        sites.filter { search.isEmpty || $0.domain.localizedCaseInsensitiveContains(search)
            || ($0.root?.localizedCaseInsensitiveContains(search) ?? false) }
    }
    private var backend: Backend { backendOverride ?? Backend(pythonExecutable: pythonExecutable, sourceDirectory: sourceDirectory) }

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
        case "section:php": await loadPHP(force: true)
        case "section:services": await loadServices(force: true)
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
            status = "\(sites.count) \(sites.count == 1 ? "site" : "sites") · Updated \(Date.now.formatted(date: .omitted, time: .shortened))"
        } catch {
            self.error = error.localizedDescription
            status = hasLoaded ? "Could not refresh · Showing previously loaded sites" : "Could not connect to MacDev"
        }
    }

    private func loadSnapshot() async throws {
        let snapshot = try await backend.snapshot()
        sites = snapshot.sites
        phpVersions = snapshot.phpVersions
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
                do { return .success(try await backend.phpDetails(version: version)) }
                catch { return .failure(error) }
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
        case .success(let details): phpDetails = details; phpError = nil
        case .failure(let error): phpError = error.localizedDescription
        }
    }

    func loadPHP(force: Bool = false) async {
        let requestID = UUID()
        phpRequestID = requestID
        let version = phpVersion
        guard !version.isEmpty else { phpDetails = nil; phpError = nil; isLoadingPHP = false; return }
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

    private func perform(_ message: String, success: String,
                         affectedPHPVersion: String? = nil,
                         invalidatesServices: Bool = true,
                         action: () async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        error = nil
        warning = nil
        status = message
        defer { isBusy = false }
        var succeeded = false
        do { try await action(); status = success; succeeded = true }
        catch { self.error = error.localizedDescription; status = "Operation failed" }
        do { try await loadSnapshot() }
        catch { self.error = [self.error, "Could not refresh: \(error.localizedDescription)"].compactMap { $0 }.joined(separator: "\n") }
        // Service status rarely changes here; re-read it when the page is next shown.
        if invalidatesServices { hasLoadedServices = false }
        if selection == "section:services" { await loadServices() }
        if let version = affectedPHPVersion {
            _ = await fetchPHP(version: version, force: true)
        }
        if selection == "section:php" { await loadPHP() }
        return succeeded
    }

    func saveSite(_ site: Site?, domain: String, root: String, version: String,
                  certificate: String, key: String) async -> Bool {
        await perform(site == nil ? "Creating site…" : "Saving site…", success: "Site saved") {
            let result = try await backend.saveSite(site: site, domain: domain, root: root,
                                                    version: version, certificate: certificate, key: key)
            selection = result.id
            search = ""
        }
    }

    func deleteSite(_ site: Site) async {
        _ = await perform("Removing \(site.domain)…", success: "Site removed · Configuration backup kept") {
            let result = try await backend.deleteSite(site)
            lastBackupPath = result.backupPath
        }
    }

    func controlService(_ service: Service, action: String) async {
        let succeeded = await perform("\(action.capitalized) \(service.name)…", success: "\(service.name): \(action) completed",
                                      invalidatesServices: false) {
            let result = try await backend.serviceAction(service, action: action)
            services = result.services
            servicesError = nil
            hasLoadedServices = true
            warning = result.warning
        }
        // A failed action may still have changed state; show what Homebrew reports.
        if !succeeded && !isBusy { await loadServices(force: true) }
    }

    func savePHP(_ details: PHPDetails, values: [String: String]) async -> Bool {
        await perform("Saving PHP \(details.version) settings…", success: "PHP settings saved", affectedPHPVersion: details.version) {
            warning = try await backend.savePHPSettings(details, values: values).warning
        }
    }

    func manageExtension(_ details: PHPDetails, name: String, action: String) async -> Bool {
        await perform("\(action.capitalized) \(name) for PHP \(details.version)…",
                      success: "Extension \(action) completed", affectedPHPVersion: details.version) {
            warning = try await backend.extensionAction(details, name: name, action: action).warning
        }
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
            status = result.changed ? "\(site.domain) now uses PHP \(version)" : "\(site.domain) already uses PHP \(version)"
        } catch {
            self.error = error.localizedDescription
            status = "PHP change failed"
        }
        // Refresh even on failure: disk state may have been restored by the backend.
        do { try await loadSnapshot() }
        catch {
            self.error = [self.error, "Could not refresh sites: \(error.localizedDescription)"].compactMap { $0 }.joined(separator: "\n")
        }
    }

    func saveInterpreter(_ path: String) async {
        guard !isBusy, !isStarting, !isLoadingPHP, !isLoadingServices else { return }
        pythonExecutable = path.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(pythonExecutable, forKey: "pythonExecutable")
        phpCache.removeAll()
        phpLoads.removeAll()
        phpRequestID = UUID()
        phpDetails = nil
        phpError = nil
        hasLoaded = false
        hasLoadedServices = false
        services = []
        didPreload = false
        await preload()
    }

    func openSite(_ site: Site) {
        guard let url = site.url, NSWorkspace.shared.open(url) else {
            error = "Could not open this site's address."
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
