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

    enum CodingKeys: String, CodingKey {
        case id, domain, root, fpm, certificate
        case phpVersion = "php_version"
        case configPath = "config_path"
        case canSwitchPHP = "can_switch_php"
        case revision
        case canEdit = "can_edit"
        case canDelete = "can_delete"
    }

    public var url: URL? {
        // Only literal host names can be opened; nginx also accepts patterns.
        guard domain.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9._-]*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return URL(string: "\(certificate == nil ? "http" : "https")://\(domain)")
    }
}

public struct Snapshot: Decodable, Sendable {
    public let sites: [Site]
    public let phpVersions: [String]

    enum CodingKeys: String, CodingKey {
        case sites
        case phpVersions = "php_versions"
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
    public let iniPath: String
    public let scanDirectory: String
    public let settings: [String: String]
    public let extensions: [PHPExtension]
    public let revision: String
    public let service: String
    public let installerAvailable: Bool
    public let diagnostics: String?
    enum CodingKeys: String, CodingKey {
        case version, settings, extensions, revision, service, diagnostics
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
