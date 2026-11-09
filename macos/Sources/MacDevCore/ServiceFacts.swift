import Foundation

/// Read-only facts about one Homebrew service, from `service-details`.
public struct ServiceDetails: Decodable, Sendable {
    public let name: String
    public let status: String
    public let pid: Int?
    public let exitCode: Int?
    public let user: String?
    public let runsAsRoot: Bool
    /// The command launchd runs, shell-escaped as Homebrew prints it.
    public let command: String?
    public let plist: String?
    public let workingDirectory: String?
    /// Seconds since the main process started.
    public let uptime: Int?
    /// Resident memory of the main process and all of its children, in bytes.
    public let memory: Int64?
    public let processCount: Int
    /// nil when the listening sockets could not be read.
    public let ports: [ServicePort]?
    public let logs: [ServiceLog]
    public let canCheck: Bool
    /// Why the service failed or cannot be controlled here, phrased for people.
    public let explanation: String?
    /// A Terminal command that may fix the problem; MacDev never runs it.
    public let terminalCommand: String?

    enum CodingKeys: String, CodingKey {
        case name, status, pid, user, command, plist, uptime, memory, ports, logs, explanation
        case exitCode = "exit_code"
        case runsAsRoot = "runs_as_root"
        case workingDirectory = "working_directory"
        case processCount = "process_count"
        case canCheck = "can_check"
        case terminalCommand = "terminal_command"
    }

    /// "localhost:6379, *:8080": one entry per port, loopback addresses merged.
    public var portSummary: String? {
        guard let ports, !ports.isEmpty else { return nil }
        var groups: [(port: Int, protocol: String, hosts: [String])] = []
        for port in ports {
            if let index = groups.firstIndex(where: { $0.port == port.port && $0.protocol == port.protocol }) {
                groups[index].hosts.append(port.host)
            } else {
                groups.append((port.port, port.protocol, [port.host]))
            }
        }
        return groups.map { group in
            ServicePort.describe(hosts: group.hosts, port: group.port)
                + (group.protocol == "TCP" ? "" : " (\(group.protocol))")
        }
        .joined(separator: ", ")
    }

    /// "12.6 MB · 3 processes"
    public var memorySummary: String? {
        guard let memory else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory)
        return processCount > 1 ? "\(size) · \(processCount) processes" : size
    }

    /// "11 days, 1 hour"
    public var uptimeSummary: String? {
        guard let uptime else { return nil }
        if uptime < 60 { return "Less than a minute" }
        return Duration.seconds(uptime).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2))
    }
}

public struct ServicePort: Decodable, Equatable, Sendable {
    public let `protocol`: String
    public let host: String
    public let port: Int

    static let loopback: Set<String> = ["127.0.0.1", "::1", "localhost"]
    static let wildcard: Set<String> = ["*", "0.0.0.0", "::"]

    /// "*:80" for every interface, "localhost:6379" for this Mac only, otherwise each address.
    static func describe(hosts: [String], port: Int) -> String {
        if hosts.contains(where: wildcard.contains) { return "*:\(port)" }
        if hosts.allSatisfy(loopback.contains) { return "localhost:\(port)" }
        return hosts.map { $0.contains(":") ? "[\($0)]:\(port)" : "\($0):\(port)" }.joined(separator: ", ")
    }
}

/// A log the service writes, named by its launchd job or its own configuration.
public struct ServiceLog: Decodable, Identifiable, Equatable, Sendable {
    public let kind: String
    public let title: String
    public let path: String
    public let exists: Bool
    public let size: Int64?
    public let modified: String?
    public var id: String { kind }
    public var modifiedDate: Date? { modified.flatMap { try? Date($0, strategy: .iso8601) } }
}

/// The result of a service's own configuration test, such as `nginx -t`.
public struct ServiceCheck: Decodable, Sendable {
    public let command: String
    public let ok: Bool
    public let output: String
}
