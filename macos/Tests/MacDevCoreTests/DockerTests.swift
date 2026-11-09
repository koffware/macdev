import Foundation
import XCTest

@testable import MacDevCore

final class DockerTests: XCTestCase {
    private func container(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var fields: [String: Any] = [
            "id": String(repeating: "a", count: 64), "name": "app-web-1", "image": "nginx:1.29",
            "image_id": "sha256:1", "state": "running", "exit_code": 0, "error": NSNull(), "oom_killed": false,
            "health": NSNull(), "created": "2026-09-09T16:01:45Z", "started_at": "2026-11-07T10:00:00Z",
            "finished_at": NSNull(), "command": "nginx -g 'daemon off;'", "restart_policy": "unless-stopped",
            "project": "app", "service": "web", "working_dir": "/work/app",
            "config_files": ["/work/app/compose.yaml"], "depends_on": ["db"],
            "ports": [["container_port": 80, "protocol": "tcp", "host_port": 8080, "host_ips": ["0.0.0.0", "::"]]],
            "mounts": [
                ["type": "bind", "name": NSNull(), "source": "/work/app", "destination": "/var/www", "read_only": true]
            ],
        ]
        fields.merge(overrides) { $1 }
        return fields
    }

    private func state(_ containers: [[String: Any]], images: [[String: Any]] = []) throws -> DockerState {
        let json: [String: Any] = [
            "protocol_version": 1, "ok": true,
            "data": [
                "installed": true, "running": true, "context": "desktop-linux", "version": "29.9.2",
                "platform": "Docker Desktop 4.98.0", "error": NSNull(), "containers": containers, "images": images,
            ],
        ]
        return try JSONDecoder().decode(Response<DockerState>.self, from: JSONSerialization.data(withJSONObject: json))
            .value(exitCode: 0)
    }

    private func decode(_ overrides: [String: Any]) throws -> DockerContainer {
        try JSONDecoder().decode(
            DockerContainer.self, from: JSONSerialization.data(withJSONObject: container(overrides)))
    }

    func testGroupsContainersByComposeProject() throws {
        let docker = try state([
            container(["id": "1", "name": "app-web-1", "service": "web"]),
            container(["id": "2", "name": "app-db-1", "service": "db", "state": "exited"]),
            container(["id": "3", "name": "redis", "project": NSNull(), "service": NSNull()]),
            container(["id": "4", "name": "api-php-1", "project": "api", "service": "php"]),
        ])
        XCTAssertEqual(docker.projects.map(\.name), ["api", "app"])
        let app = try XCTUnwrap(docker.project(named: "app"))
        XCTAssertEqual(app.containers.map(\.displayName), ["db", "web"])
        XCTAssertEqual(app.summary, "1 of 2 running")
        XCTAssertEqual(app.workingDir, "/work/app")
        XCTAssertEqual(app.configFiles, ["/work/app/compose.yaml"])
        XCTAssertEqual(docker.project(named: "api")?.summary, "Running")
        XCTAssertEqual(docker.standaloneContainers.map(\.name), ["redis"])
        XCTAssertEqual(docker.runningCount, 3)
    }

    func testStatusTitles() throws {
        XCTAssertEqual(try decode([:]).statusTitle, "Running")
        XCTAssertEqual(try decode(["health": "unhealthy"]).statusTitle, "Running · Unhealthy")
        XCTAssertTrue(try decode(["health": "unhealthy"]).hasError)
        // A stopped container keeps its last health status; it no longer means anything.
        let stopped = try decode(["state": "exited", "exit_code": 137, "health": "unhealthy"])
        XCTAssertEqual(stopped.statusTitle, "Stopped")
        XCTAssertFalse(stopped.hasError)
        let crashed = try decode(["state": "exited", "exit_code": 1])
        XCTAssertEqual(crashed.statusTitle, "Exited with code 1")
        XCTAssertTrue(crashed.hasError)
        XCTAssertEqual(
            try decode(["state": "exited", "exit_code": 137, "oom_killed": true]).statusTitle,
            "Stopped · Out of memory")
        XCTAssertEqual(try decode(["state": "created"]).statusTitle, "Created · Never started")
        XCTAssertFalse(try decode([:]).canRemove)
        XCTAssertTrue(stopped.canRemove)
    }

    func testPortsAndMounts() throws {
        let web = try decode([:])
        XCTAssertEqual(web.ports.first?.summary, "*:8080 → 80")
        XCTAssertEqual(web.browserURLs, [URL(string: "http://localhost:8080")])
        let local = try decode([
            "ports": [
                ["container_port": 443, "protocol": "tcp", "host_port": 8443, "host_ips": ["127.0.0.1"]],
                ["container_port": 53, "protocol": "udp", "host_port": 5353, "host_ips": ["0.0.0.0"]],
                ["container_port": 1025, "protocol": "tcp", "host_port": NSNull(), "host_ips": ["0.0.0.0"]],
            ]
        ])
        XCTAssertEqual(local.ports.map(\.summary), ["localhost:8443 → 443", "*:5353 → 53/udp", "Any free port → 1025"])
        XCTAssertEqual(local.browserURLs, [URL(string: "https://localhost:8443")])
        XCTAssertEqual(web.mounts.first?.origin, "/work/app")
        XCTAssertEqual(web.mounts.first?.readOnly, true)
    }

    func testUptimeOnlyWhileRunning() throws {
        let now = try Date("2026-11-07T12:30:00Z", strategy: .iso8601)
        XCTAssertEqual(try decode([:]).uptime(now: now), "2 hours, 30 minutes")
        XCTAssertNil(try decode(["state": "exited"]).uptime(now: now))
    }

    func testImages() throws {
        let image: [String: Any] = [
            "id": "sha256:1" + String(repeating: "0", count: 63), "tags": ["nginx:1.29", "nginx:latest"],
            "size": 1_000_000, "created": "2026-10-01T00:00:00Z", "containers": 1,
        ]
        let dangling: [String: Any] = [
            "id": "sha256:abcdef1234567890", "tags": [String](), "size": NSNull(), "created": NSNull(), "containers": 0,
        ]
        let docker = try state([container(["image_id": image["id"] ?? ""])], images: [image, dangling])
        XCTAssertEqual(docker.images[0].title, "nginx:1.29")
        XCTAssertEqual(docker.containers(using: docker.images[0]).map(\.name), ["app-web-1"])
        XCTAssertEqual(docker.images[1].title, "Untagged · abcdef123456")
        XCTAssertEqual(docker.danglingImages.count, 1)
    }

    func testEngineNotRunningDecodes() throws {
        let json =
            #"{"protocol_version":1,"ok":true,"data":{"installed":true,"running":false,"context":null,"version":null,"platform":null,"error":"Cannot connect to the Docker daemon","containers":[],"images":[]}}"#
        let docker = try JSONDecoder().decode(Response<DockerState>.self, from: Data(json.utf8)).value(exitCode: 0)
        XCTAssertFalse(docker.running)
        XCTAssertEqual(docker.error, "Cannot connect to the Docker daemon")
        XCTAssertTrue(docker.projects.isEmpty)
    }
}
