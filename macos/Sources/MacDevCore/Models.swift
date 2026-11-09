import Foundation

public struct Site: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let domain: String
    public let root: String?
    public let phpVersion: String?
    public let fpm: String?
    public let certificate: String?
    public let configPath: String
    public let canSwitchPHP: Bool
    public let revision: String?
    public let canEdit: Bool?
    public let canDelete: Bool?
    public let rootExists: Bool?
    public let projectRoot: String?
    public let framework: String?
    public let frameworkVersion: String?
    /// composer.json `require.php`, e.g. ">=8.4".
    public let phpRequirement: String?
    /// Installed PHP versions that satisfy `phpRequirement`; nil when it could not be evaluated.
    public let phpSupportedVersions: [String]?
    public let certificateKey: String?
    /// ISO 8601, e.g. "2028-08-15T17:08:12Z".
    public let certificateExpires: String?
    public let certificateNames: [String]?
    /// A problem the backend found with the certificate files, phrased for people.
    public let certificateIssue: String?
    /// Raw nginx values such as "50m" and "60s"; nil when the site leaves nginx's default.
    public let clientMaxBodySize: String?
    public let fastcgiReadTimeout: String?
    public let logs: [SiteLog]?

    enum CodingKeys: String, CodingKey {
        case id, domain, root, fpm, certificate, framework, logs
        case phpVersion = "php_version"
        case configPath = "config_path"
        case canSwitchPHP = "can_switch_php"
        case revision
        case canEdit = "can_edit"
        case canDelete = "can_delete"
        case rootExists = "root_exists"
        case projectRoot = "project_root"
        case frameworkVersion = "framework_version"
        case phpRequirement = "php_requirement"
        case phpSupportedVersions = "php_supported_versions"
        case certificateKey = "certificate_key"
        case certificateExpires = "certificate_expires"
        case certificateNames = "certificate_names"
        case certificateIssue = "certificate_issue"
        case clientMaxBodySize = "client_max_body_size"
        case fastcgiReadTimeout = "fastcgi_read_timeout"
    }

    public var isSecure: Bool { certificate != nil }

    /// "Symfony 8.1", or "PHP" / "Static" when no framework was detected.
    public var stackTitle: String {
        if let framework { return [framework, frameworkVersion].compactMap { $0 }.joined(separator: " ") }
        return fpm == nil ? "Static" : "PHP"
    }

    /// Framework and PHP version on one line, e.g. "Symfony 8.1 · PHP 8.4".
    public var summary: String {
        guard fpm != nil else { return stackTitle }
        let php = phpVersion.map { "PHP \($0)" } ?? "PHP unknown"
        return framework == nil ? php : "\(stackTitle) · \(php)"
    }

    /// Whether the site can serve requests, given Homebrew service status, its certificate,
    /// and the project's PHP requirement. Returns nil while service status is unknown and
    /// nothing else is wrong.
    public func health(services: [Service], phpService: String?, now: Date = .now) -> SiteHealth? {
        if rootExists == false {
            return .problem(root == nil ? "No document root configured" : "Project folder is missing")
        }
        let certificate = certificateHealth(now: now)
        if case .problem = certificate { return certificate }
        let runtime = runtimeHealth(services: services, phpService: phpService)
        if let runtime, runtime != .ok { return runtime }
        if requirementMet == false, let phpRequirement { return .warning("Project requires PHP \(phpRequirement)") }
        if case .warning = certificate { return certificate }
        return runtime
    }

    private func runtimeHealth(services: [Service], phpService: String?) -> SiteHealth? {
        guard !services.isEmpty else { return nil }
        if let nginx = services.first(where: { $0.name == "nginx" }), !nginx.isRunning {
            return .problem("nginx is not running")
        }
        if fpm != nil {
            guard let phpVersion else { return .warning("Uses a PHP-FPM address no installed PHP version listens on") }
            if let phpService, let service = services.first(where: { $0.name == phpService }), !service.isRunning {
                return .warning("PHP \(phpVersion) is not running")
            }
        }
        return .ok
    }

    /// Whether the project's composer.json allows PHP VERSION; nil when there is no readable requirement.
    public func supports(phpVersion version: String) -> Bool? {
        phpSupportedVersions.map { $0.contains(version) }
    }

    /// Whether the site's current PHP version satisfies the project's requirement.
    public var requirementMet: Bool? {
        guard fpm != nil, let phpVersion else { return nil }
        return supports(phpVersion: phpVersion)
    }

    public var certificateExpiryDate: Date? {
        certificateExpires.flatMap { try? Date($0, strategy: .iso8601) }
    }

    /// Certificates within this many days of expiry are reported as a warning.
    public static let certificateWarningDays = 30

    /// Problems with the certificate files, expiry, or the names it covers; nil without HTTPS.
    public func certificateHealth(now: Date = .now) -> SiteHealth? {
        guard certificate != nil else { return nil }
        if let certificateIssue {
            return certificateIssue.contains("does not cover") ? .warning(certificateIssue) : .problem(certificateIssue)
        }
        guard let expiry = certificateExpiryDate else { return .ok }
        if expiry <= now {
            return .problem("Certificate expired on \(expiry.formatted(date: .abbreviated, time: .omitted))")
        }
        let days = Calendar.current.dateComponents([.day], from: now, to: expiry).day ?? 0
        if days < Self.certificateWarningDays {
            return .warning(
                days < 1 ? "Certificate expires today" : "Certificate expires in \(days) \(days == 1 ? "day" : "days")")
        }
        return .ok
    }

    public var url: URL? {
        // Only literal host names can be opened; nginx also accepts patterns.
        guard domain.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9._-]*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return URL(string: "\(certificate == nil ? "http" : "https")://\(domain)")
    }
}

public enum SiteHealth: Equatable, Sendable {
    case ok
    case warning(String)
    case problem(String)

    public var message: String {
        switch self {
        case .ok: "Running"
        case .warning(let message), .problem(let message): message
        }
    }
}

public struct Snapshot: Decodable, Sendable {
    public let sites: [Site]
    public let phpVersions: [String]
    /// Homebrew service name per PHP version, e.g. "8.4": "php@8.4".
    public let phpServices: [String: String]?
    /// The version Homebrew links as `php`, used by Terminal unless the shell's PATH says otherwise.
    public let phpCLIVersion: String?
    /// Whether a `docker` CLI is installed; the engine itself may not be running.
    public let dockerInstalled: Bool?

    enum CodingKeys: String, CodingKey {
        case sites
        case phpVersions = "php_versions"
        case phpServices = "php_services"
        case phpCLIVersion = "php_cli_version"
        case dockerInstalled = "docker_installed"
    }
}

public struct PHPChange: Decodable, Sendable {
    public let changed: Bool
    public let warning: String?
}

public struct MutationResult: Decodable, Sendable {
    public let id: String?
    public let changed: Bool?
    public let backupPath: String?
    enum CodingKeys: String, CodingKey {
        case id, changed
        case backupPath = "backup_path"
    }
}

public struct Service: Decodable, Identifiable, Sendable {
    public let name: String
    public let status: String
    public let user: String?
    public let exitCode: Int?
    public var id: String { name }
    public var isRunning: Bool { status == "started" }
    public var hasError: Bool { status == "error" }
    public var isRegistered: Bool { status != "none" && status != "stopped" }
    /// Homebrew's raw status words, phrased for people.
    public var statusTitle: String {
        switch status {
        case "started": "Running"
        case "stopped": "Stopped"
        case "none": "Not started"
        case "scheduled": "Scheduled"
        case "error": "Error"
        case "other": "Unknown state"
        default: status.capitalized
        }
    }
    enum CodingKeys: String, CodingKey {
        case name, status, user
        case exitCode = "exit_code"
    }
}

public struct ServiceList: Decodable, Sendable {
    public let services: [Service]
    public let warning: String?
}

public struct PHPExtension: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let enabled: Bool
    public let loaded: Bool
    public let builtin: Bool
    public let version: String?
    public let package: String?
    public let canToggle: Bool
    public let canRemove: Bool
    public let sources: [String]
    public let iniPath: String?
    public let canSeparateIni: Bool?
    /// Present and switched on in the FPM configuration (built-in modules always are).
    public var isActive: Bool { builtin || (enabled && loaded) }
    enum CodingKeys: String, CodingKey {
        case id, name, enabled, loaded, builtin, version, package, sources
        case canToggle = "can_toggle"
        case canRemove = "can_remove"
        case iniPath = "ini_path"
        case canSeparateIni = "can_separate_ini"
    }
}

public struct PHPDetails: Decodable, Sendable {
    public let version: String
    /// The full release, e.g. "8.4.7".
    public let release: String?
    public let binary: String?
    /// The FPM pool's listen address from www.conf.
    public let fpmListen: String?
    public let iniPath: String
    public let scanDirectory: String
    public let settings: [String: String]
    public let extensions: [PHPExtension]
    public let revision: String
    public let service: String
    public let installerAvailable: Bool
    public let diagnostics: String?
    enum CodingKeys: String, CodingKey {
        case version, release, binary, settings, extensions, revision, service, diagnostics
        case fpmListen = "fpm_listen"
        case iniPath = "ini_path"
        case scanDirectory = "scan_directory"
        case installerAvailable = "installer_available"
    }
}

public enum BackendError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

public struct Response<Value: Decodable>: Decodable {
    public let protocolVersion: Int
    public let ok: Bool
    public let data: Value?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case ok, data, error
    }

    public func value(exitCode: Int32) throws -> Value {
        guard protocolVersion == 1 else {
            throw BackendError.message("This MacDev backend uses an unsupported interface version. Rebuild the app.")
        }
        guard ok, exitCode == 0, let data else {
            throw BackendError.message(error ?? "MacDev could not complete the operation.")
        }
        return data
    }
}
