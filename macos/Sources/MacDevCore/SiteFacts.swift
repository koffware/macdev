import Foundation

/// An access or error log named in a site's nginx config.
public struct SiteLog: Decodable, Identifiable, Equatable, Sendable {
    public let kind: String
    public let path: String
    public let exists: Bool
    public let size: Int64?
    /// ISO 8601, e.g. "2026-11-04T16:15:21Z".
    public let modified: String?
    public var id: String { kind }
    public var title: String { kind == "error" ? "Error log" : "Access log" }
    public var modifiedDate: Date? { modified.flatMap { try? Date($0, strategy: .iso8601) } }
}

public struct LogTail: Decodable, Sendable {
    public let path: String
    public let lines: [String]
    public let exists: Bool
}

/// Parses nginx and PHP size and time values.
public enum ConfigValue {
    /// "50m", "2M", "1G", "512k", "1048576" → bytes. "0" means no limit in both nginx and PHP.
    public static func bytes(_ raw: String?) -> Int64? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        let units: [Character: Int64] = ["k": 1024, "m": 1024 * 1024, "g": 1024 * 1024 * 1024]
        if let last = raw.last, let unit = units[last] {
            return Int64(raw.dropLast()).map { $0 * unit }
        }
        return Int64(raw)
    }

    /// nginx "60s", "2m", "1h", "90" or PHP "30" → seconds.
    public static func seconds(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        let units: [Character: Int] = ["s": 1, "m": 60, "h": 3600, "d": 86_400]
        if let last = raw.last, let unit = units[last] {
            if raw.hasSuffix("ms") { return Int(raw.dropLast(2)).map { $0 / 1000 } }
            return Int(raw.dropLast()).map { $0 * unit }
        }
        return Int(raw)
    }

    public static func size(_ bytes: Int64) -> String {
        bytes == 0 ? "No limit" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    public static func duration(_ seconds: Int) -> String {
        if seconds == 0 { return "No limit" }
        if seconds < 60 || !seconds.isMultiple(of: 60) { return "\(seconds) s" }
        return seconds.isMultiple(of: 3600) ? "\(seconds / 3600) h" : "\(seconds / 60) min"
    }
}

/// nginx request limits for one site next to the FPM defaults of its PHP version.
public struct RequestLimits: Equatable, Sendable {
    /// nginx's built-in values, used when neither the site nor nginx.conf sets one.
    public static let nginxDefaultBody: Int64 = 1024 * 1024
    public static let nginxDefaultTimeout = 60

    public let nginxBody: Int64?
    public let nginxTimeout: Int?
    public let uploadMax: Int64?
    public let postMax: Int64?
    public let executionTime: Int?

    public init(site: Site, phpSettings: [String: String]?) {
        nginxBody = ConfigValue.bytes(site.clientMaxBodySize)
        nginxTimeout = site.fpm == nil ? nil : ConfigValue.seconds(site.fastcgiReadTimeout)
        uploadMax = ConfigValue.bytes(phpSettings?["upload_max_filesize"])
        postMax = ConfigValue.bytes(phpSettings?["post_max_size"])
        executionTime = ConfigValue.seconds(phpSettings?["max_execution_time"])
    }

    /// The largest upload PHP accepts: the smaller of upload_max_filesize and post_max_size.
    public var phpUpload: Int64? {
        let limits = [uploadMax, postMax].compactMap { $0 }.filter { $0 > 0 }
        if limits.isEmpty { return uploadMax == nil && postMax == nil ? nil : 0 }
        return limits.min()
    }

    /// Why uploads that nginx accepts can still fail in PHP; nil when the limits agree.
    public var uploadWarning: String? {
        if let uploadMax, let postMax, postMax > 0, uploadMax > postMax {
            return
                "post_max_size (\(ConfigValue.size(postMax))) is smaller than upload_max_filesize (\(ConfigValue.size(uploadMax))), so the whole request is rejected first."
        }
        guard let phpUpload, phpUpload > 0 else { return nil }
        let nginx = nginxBody ?? Self.nginxDefaultBody
        guard nginx == 0 || nginx > phpUpload else { return nil }
        return
            "nginx accepts \(nginx == 0 ? "uploads of any size" : "up to \(ConfigValue.size(nginx))"), but PHP drops files over \(ConfigValue.size(phpUpload)). Larger uploads arrive empty instead of failing with an error."
    }

    /// Why long requests can end in 504 before PHP's own limit; nil when they agree.
    public var timeoutWarning: String? {
        guard let executionTime else { return nil }
        let nginx = nginxTimeout ?? Self.nginxDefaultTimeout
        guard nginx > 0, executionTime == 0 || executionTime > nginx else { return nil }
        let php = executionTime == 0 ? "has no time limit" : "allows \(ConfigValue.duration(executionTime))"
        return
            "nginx stops waiting for PHP after \(ConfigValue.duration(nginx)), but PHP \(php). Long requests and debugger sessions end with 504 Gateway Timeout."
    }
}
