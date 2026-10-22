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
    @Published var phpVersion = ""
    @Published private(set) var lastBackupPath: String?

    private let sourceDirectory: URL
    private var phpRequestID = UUID()

    init() {
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
    private var backend: Backend { Backend(pythonExecutable: pythonExecutable, sourceDirectory: sourceDirectory) }

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
        hasLoaded = true
        if selection?.hasPrefix("section:") != true && !sites.contains(where: { $0.id == selection }) {
            selection = sites.first?.id
        }
        if !phpVersions.contains(phpVersion) { phpVersion = phpVersions.first ?? "" }
    }

    func loadServices() async {
        guard !isLoadingServices else { return }
        isLoadingServices = true
        servicesError = nil
        defer { isLoadingServices = false }
        do { services = try await backend.services().services }
        catch { servicesError = error.localizedDescription }
    }

    func loadPHP() async {
        let requestID = UUID()
        phpRequestID = requestID
        let version = phpVersion
        guard !version.isEmpty else { phpDetails = nil; return }
        isLoadingPHP = true
        phpError = nil
        if phpDetails?.version != version { phpDetails = nil }
        defer { if phpRequestID == requestID { isLoadingPHP = false } }
        do {
            let details = try await backend.phpDetails(version: version)
            if phpRequestID == requestID { phpDetails = details }
        } catch { if phpRequestID == requestID { phpError = error.localizedDescription } }
    }

    private func perform(_ message: String, success: String,
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
        if selection == "section:services" { await loadServices() }
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
        _ = await perform("\(action.capitalized) \(service.name)…", success: "\(service.name): \(action) completed") {
            let result = try await backend.serviceAction(service, action: action)
            services = result.services
            warning = result.warning
        }
    }

    func savePHP(_ details: PHPDetails, values: [String: String]) async -> Bool {
        await perform("Saving PHP \(details.version) settings…", success: "PHP settings saved") {
            warning = try await backend.savePHPSettings(details, values: values).warning
        }
    }

    func manageExtension(_ details: PHPDetails, name: String, action: String) async -> Bool {
        await perform("\(action.capitalized) \(name) for PHP \(details.version)…",
                      success: "Extension \(action) completed") {
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
        pythonExecutable = path.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(pythonExecutable, forKey: "pythonExecutable")
        await refresh()
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
