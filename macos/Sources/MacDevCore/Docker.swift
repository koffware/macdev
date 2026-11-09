import Foundation

/// The Docker engine as the `docker` CLI reports it, from the `docker` operation.
public struct DockerState: Decodable, Sendable {
    public let installed: Bool
    public let running: Bool
    /// The CLI context in use, such as "desktop-linux" or "orbstack".
    public let context: String?
    public let version: String?
    /// "Docker Desktop 4.98.0 (245422)"; nil for engines that do not name themselves.
    public let platform: String?
    /// Why the engine could not be reached, as the CLI phrased it.
    public let error: String?
    public let containers: [DockerContainer]
    public let images: [DockerImage]
    /// A one-line result of the last action, such as the space an image prune reclaimed.
    public let message: String?

    /// Compose projects by name, then containers that belong to no project.
    public var projects: [DockerProject] {
        Dictionary(grouping: containers.filter { $0.project != nil }) { $0.project ?? "" }
            .map { DockerProject(name: $0.key, containers: $0.value.sorted { $0.displayName < $1.displayName }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public var standaloneContainers: [DockerContainer] {
        containers.filter { $0.project == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public var runningCount: Int { containers.count(where: \.isRunning) }
    public var danglingImages: [DockerImage] { images.filter(\.isDangling) }

    public func container(id: String) -> DockerContainer? { containers.first { $0.id == id } }
    public func project(named name: String) -> DockerProject? { projects.first { $0.name == name } }
    public func containers(using image: DockerImage) -> [DockerContainer] {
        containers.filter { $0.imageID == image.id }
    }
}

public struct DockerContainer: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let image: String?
    public let imageID: String?
    /// Docker's state word: created, running, paused, restarting, exited, removing, or dead.
    public let state: String
    public let exitCode: Int?
    public let error: String?
    public let oomKilled: Bool
    /// healthy, unhealthy, or starting; nil without a health check.
    public let health: String?
    public let created: String?
    public let startedAt: String?
    public let finishedAt: String?
    public let command: String?
    public let restartPolicy: String?
    public let project: String?
    public let service: String?
    public let workingDir: String?
    public let configFiles: [String]
    public let dependsOn: [String]
    public let ports: [DockerPort]
    public let mounts: [DockerMount]

    enum CodingKeys: String, CodingKey {
        case id, name, image, state, error, health, created, command, project, service, ports, mounts
        case imageID = "image_id"
        case exitCode = "exit_code"
        case oomKilled = "oom_killed"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case restartPolicy = "restart_policy"
        case workingDir = "working_dir"
        case configFiles = "config_files"
        case dependsOn = "depends_on"
    }

    /// Exit codes of a container that was asked to stop: SIGINT, SIGKILL after the grace period, SIGTERM.
    static let stopExitCodes: Set<Int> = [0, 130, 137, 143]

    public var shortID: String { String(id.prefix(12)) }
    /// The Compose service name inside a project, otherwise the container name.
    public var displayName: String { service ?? name }
    public var isRunning: Bool { state == "running" }
    /// Docker refuses to remove containers in these states without --force, which MacDev never uses.
    public var canRemove: Bool { !["running", "restarting", "paused", "removing"].contains(state) }
    /// The health check only means something while the container runs.
    public var currentHealth: String? { isRunning ? health : nil }

    public var hasError: Bool {
        if state == "dead" || oomKilled || currentHealth == "unhealthy" { return true }
        guard state == "exited", let exitCode else { return false }
        return !Self.stopExitCodes.contains(exitCode)
    }

    public var statusTitle: String {
        switch state {
        case "running":
            switch currentHealth {
            case "unhealthy": "Running · Unhealthy"
            case "starting": "Running · Starting"
            default: "Running"
            }
        case "exited":
            if oomKilled {
                "Stopped · Out of memory"
            } else if hasError, let exitCode {
                "Exited with code \(exitCode)"
            } else {
                "Stopped"
            }
        case "created": "Created · Never started"
        default: state.capitalized
        }
    }

    public var startedDate: Date? { startedAt.flatMap(Self.date) }
    public var finishedDate: Date? { finishedAt.flatMap(Self.date) }
    public var createdDate: Date? { created.flatMap(Self.date) }

    /// "2 hours", the time since the container started, while it runs.
    public func uptime(now: Date = .now) -> String? {
        guard isRunning, let startedDate else { return nil }
        let seconds = Int(now.timeIntervalSince(startedDate))
        if seconds < 60 { return "Less than a minute" }
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2))
    }

    /// Published host ports that answer HTTP on this Mac, for "Open in Browser".
    public var browserURLs: [URL] { ports.compactMap(\.browserURL) }

    static func date(_ value: String) -> Date? { try? Date(value, strategy: .iso8601) }
}

public struct DockerPort: Decodable, Equatable, Sendable {
    public let containerPort: Int
    public let `protocol`: String
    /// nil when Docker picks a free host port each time the container starts.
    public let hostPort: Int?
    public let hostIPs: [String]

    enum CodingKeys: String, CodingKey {
        case `protocol`
        case containerPort = "container_port"
        case hostPort = "host_port"
        case hostIPs = "host_ips"
    }

    /// "localhost:8080 → 80", "*:5432 → 5432/udp", "Any free port → 1025".
    public var summary: String {
        let target = `protocol` == "tcp" ? "\(containerPort)" : "\(containerPort)/\(`protocol`)"
        guard let hostPort else { return "Any free port → \(target)" }
        return "\(ServicePort.describe(hosts: hostIPs, port: hostPort)) → \(target)"
    }

    public var browserURL: URL? {
        guard `protocol` == "tcp", let hostPort else { return nil }
        let scheme = [443, 8443].contains(containerPort) ? "https" : "http"
        return URL(string: "\(scheme)://localhost:\(hostPort)")
    }
}

public struct DockerMount: Decodable, Equatable, Sendable {
    /// bind, volume, tmpfs, or npipe.
    public let type: String
    public let name: String?
    /// For bind mounts, a folder on this Mac; for volumes, a path inside Docker's virtual machine.
    public let source: String?
    public let destination: String
    public let readOnly: Bool

    enum CodingKeys: String, CodingKey {
        case type, name, source, destination
        case readOnly = "read_only"
    }

    public var isBind: Bool { type == "bind" }
    /// The folder or volume name people recognise.
    public var origin: String { isBind ? (source ?? "Unknown folder") : (name ?? type) }
}

public struct DockerImage: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let tags: [String]
    public let size: Int64?
    public let created: String?
    /// Containers of any state created from this image.
    public let containers: Int

    public var isDangling: Bool { tags.isEmpty }
    public var shortID: String { String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12)) }
    public var title: String { tags.first ?? "Untagged · \(shortID)" }
    public var createdDate: Date? { created.flatMap(DockerContainer.date) }
    public var sizeSummary: String? {
        size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}

/// Containers that share a `com.docker.compose.project` label.
public struct DockerProject: Identifiable, Equatable, Sendable {
    public let name: String
    public let containers: [DockerContainer]
    public var id: String { name }

    public init(name: String, containers: [DockerContainer]) {
        self.name = name
        self.containers = containers
    }

    /// Every container records the folder Compose ran in; they agree unless the project was moved.
    public var workingDir: String? { containers.lazy.compactMap(\.workingDir).first }
    public var configFiles: [String] { containers.first { !$0.configFiles.isEmpty }?.configFiles ?? [] }
    public var runningCount: Int { containers.count(where: \.isRunning) }
    public var isRunning: Bool { runningCount > 0 }
    public var hasError: Bool { containers.contains(where: \.hasError) }

    /// "All 3 running", "1 of 3 running", "Stopped".
    public var summary: String {
        if runningCount == 0 { return "Stopped" }
        if runningCount == containers.count {
            return containers.count == 1 ? "Running" : "All \(containers.count) running"
        }
        return "\(runningCount) of \(containers.count) running"
    }
}

/// The last lines a container wrote to stdout and stderr.
public struct ContainerLog: Decodable, Sendable {
    public let lines: [String]
}
