import Foundation

public struct Backend: Sendable {
    public let pythonExecutable: String
    public let sourceDirectory: URL

    public init(pythonExecutable: String, sourceDirectory: URL) {
        self.pythonExecutable = pythonExecutable
        self.sourceDirectory = sourceDirectory
    }

    public func snapshot() async throws -> Snapshot {
        try await request(["snapshot"])
    }

    public func switchPHP(siteID: String, version: String) async throws -> PHPChange {
        try await request(["switch-php", "--site", siteID, "--version", version])
    }

    public func saveSite(site: Site?, domain: String, root: String, version: String,
                         certificate: String, key: String) async throws -> MutationResult {
        var arguments = [site == nil ? "create-site" : "update-site", "--domain", domain, "--root", root]
        if let site {
            guard let revision = site.revision else { throw BackendError.message("Refresh sites before editing.") }
            arguments += ["--site", site.id, "--revision", revision]
        }
        if !version.isEmpty { arguments += ["--version", version] }
        if !certificate.isEmpty || !key.isEmpty { arguments += ["--cert", certificate, "--key", key] }
        return try await request(arguments)
    }

    public func deleteSite(_ site: Site) async throws -> MutationResult {
        guard let revision = site.revision else { throw BackendError.message("Refresh sites before removing.") }
        return try await request(["delete-site", "--site", site.id, "--revision", revision])
    }

    public func services() async throws -> ServiceList { try await request(["services"]) }

    public func serviceAction(_ service: Service, action: String) async throws -> ServiceList {
        try await request(["service-action", "--service", service.name, "--action", action])
    }

    public func phpDetails(version: String) async throws -> PHPDetails {
        try await request(["php-details", "--version", version])
    }

    public func savePHPSettings(_ details: PHPDetails, values: [String: String]) async throws -> PHPChange {
        let json = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        return try await request(["php-settings", "--version", details.version,
                                  "--revision", details.revision, "--values", json])
    }

    public func extensionAction(_ details: PHPDetails, name: String, action: String) async throws -> PHPChange {
        try await request(["extension", "--version", details.version, "--revision", details.revision,
                           "--name", name, "--action", action])
    }

    private func request<Value: Decodable & Sendable>(_ arguments: [String]) async throws -> Value {
        // All subprocess work and waiting happen off the UI thread.
        try await Task.detached {
            let result = try Self.run(
                executable: self.pythonExecutable,
                arguments: ["-m", "macdev.api"] + arguments,
                sourceDirectory: self.sourceDirectory
            )
            do {
                return try JSONDecoder().decode(Response<Value>.self, from: result.output).value(exitCode: result.exitCode)
            } catch let error as BackendError {
                throw error
            } catch {
                let detail = String(data: result.error, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw BackendError.message(detail.isEmpty
                    ? "MacDev returned an unreadable response. Check the Python interpreter in Settings."
                    : "The backend could not start: \(detail)")
            }
        }.value
    }

    public static func environment(sourceDirectory: URL, inherited: [String: String]) -> [String: String] {
        var environment = inherited
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
                     "\(home)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = paths.joined(separator: ":") + ":" + (inherited["PATH"] ?? "")
        environment["PYTHONPATH"] = sourceDirectory.path
        environment["PYTHONNOUSERSITE"] = "1"
        // The bundled Python source is sealed by the app's code signature.
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["NO_COLOR"] = "1"
        return environment
    }

    public struct Result: Sendable {
        public let output: Data
        public let error: Data
        public let exitCode: Int32
    }

    public static func run(executable: String, arguments: [String], sourceDirectory: URL) throws -> Result {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw BackendError.message("Choose an installed Python interpreter in Settings. Its path must be absolute.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? error.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = sourceDirectory
        process.environment = environment(sourceDirectory: sourceDirectory, inherited: ProcessInfo.processInfo.environment)
        // File-backed streams cannot deadlock on a full stdout/stderr pipe.
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return Result(output: try Data(contentsOf: outputURL), error: try Data(contentsOf: errorURL),
                      exitCode: process.terminationStatus)
    }
}
