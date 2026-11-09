import Foundation
import MacDevCore
import XCTest

@testable import MacDev

final class SiteStoreTests: XCTestCase {
    private func fixture() throws -> (URL, Backend) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("backend")
        // A protocol fixture: no Homebrew, PHP, nginx, or real configuration is accessed.
        let script = #"""
            #!/bin/sh
            printf '%s %s\n' "$3" "${5-}" >> "$0.calls"
            case "$3" in
              snapshot)
                if [ -f "$0.fail-snapshot" ]; then
                  printf '%s' '{"protocol_version":1,"ok":false,"error":"Snapshot unavailable"}'
                  exit 1
                fi
                if [ -f "$0.snapshot" ]; then cat "$0.snapshot"; exit 0; fi
                printf '%s' '{"protocol_version":1,"ok":true,"data":{"sites":[],"php_versions":["8.4","8.2"]}}'
                ;;
              services)
                if [ -f "$0.fail-services" ]; then
                  printf '%s' '{"protocol_version":1,"ok":false,"error":"Services unavailable"}'
                  exit 1
                fi
                if [ -f "$0.services" ]; then cat "$0.services"; exit 0; fi
                printf '%s' '{"protocol_version":1,"ok":true,"data":{"services":[{"name":"nginx","status":"started"}]}}'
                ;;
              php-details)
                if [ -f "$0.fail-php-$5" ]; then
                  printf '%s' '{"protocol_version":1,"ok":false,"error":"PHP unavailable"}'
                  exit 1
                fi
                revision=original
                if [ -f "$0.changed" ]; then revision=updated; fi
                if [ -f "$0.slow-php-$5" ]; then touch "$0.read-php-$5"; sleep 0.5; fi
                printf '{"protocol_version":1,"ok":true,"data":{"version":"%s","ini_path":"/tmp/php.ini","scan_directory":"/tmp/conf.d","settings":{"memory_limit":"512M"},"extensions":[],"revision":"%s","service":"php@%s","installer_available":true}}' "$5" "$revision" "$5"
                ;;
              php-settings)
                touch "$0.changed"
                printf '%s' '{"protocol_version":1,"ok":true,"data":{"changed":true}}'
                ;;
            esac
            """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (executable, Backend(pythonExecutable: executable.path, sourceDirectory: directory))
    }

    private func calls(_ executable: URL, command: String) throws -> [String] {
        try String(contentsOf: URL(fileURLWithPath: executable.path + ".calls"), encoding: .utf8)
            .components(separatedBy: .newlines).filter { $0.hasPrefix(command + " ") }
    }

    private func fail(_ executable: URL, operation: String) throws {
        try Data().write(to: URL(fileURLWithPath: executable.path + ".fail-" + operation))
    }

    private func marker(_ executable: URL, _ name: String) -> String { executable.path + "." + name }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line)
        async throws
    {
        let deadline = Date.now.addingTimeInterval(5)
        while !condition() {
            guard Date.now < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    func testPreloadsEveryPageOnceAndVersionSwitchesUseCacheImmediately() async throws {
        let (executable, backend) = try fixture()
        let store = SiteStore(backend: backend)
        XCTAssertTrue(store.isStarting)
        await store.preload()
        XCTAssertFalse(store.isStarting)
        XCTAssertTrue(store.hasLoaded)
        XCTAssertEqual(store.services.first?.name, "nginx")
        XCTAssertEqual(store.phpDetails?.version, "8.4")

        for version in ["8.2", "8.4", "8.2"] {
            store.phpVersion = version
            XCTAssertEqual(store.phpDetails?.version, version)
            await store.loadPHP()
            await store.loadServices()
        }
        await store.preload()
        XCTAssertEqual(try calls(executable, command: "snapshot").count, 1)
        XCTAssertEqual(try calls(executable, command: "services").count, 1)
        XCTAssertEqual(try calls(executable, command: "php-details").count, 2)

        store.selection = "section:php"
        await store.refreshCurrentSection()
        // The PHP page shows its FPM service status, so refreshing it re-reads services too.
        XCTAssertEqual(try calls(executable, command: "php-details").count, 3)
        XCTAssertEqual(try calls(executable, command: "services").count, 2)
        store.selection = "section:services"
        await store.refreshCurrentSection()
        XCTAssertEqual(try calls(executable, command: "php-details").count, 3)
        XCTAssertEqual(try calls(executable, command: "services").count, 3)
    }

    @MainActor
    func testPreloadFailuresFinishAndCanBeRetriedExplicitly() async throws {
        let (executable, backend) = try fixture()
        try fail(executable, operation: "php-8.2")
        try fail(executable, operation: "services")
        let store = SiteStore(backend: backend)
        await store.preload()
        XCTAssertFalse(store.isStarting)
        XCTAssertNotNil(store.servicesError)
        store.phpVersion = "8.2"
        XCTAssertNil(store.phpDetails)
        XCTAssertEqual(store.phpError, "PHP unavailable")
        await store.loadPHP()
        XCTAssertEqual(try calls(executable, command: "php-details").count, 2)
        await store.loadServices()
        XCTAssertEqual(
            try calls(executable, command: "services").count, 2, "A failed services read is retried on the next visit")

        try FileManager.default.removeItem(atPath: executable.path + ".fail-php-8.2")
        try FileManager.default.removeItem(atPath: executable.path + ".fail-services")
        await store.loadPHP(force: true)
        await store.loadServices()
        XCTAssertNil(store.phpError)
        XCTAssertNil(store.servicesError)
        XCTAssertEqual(store.phpDetails?.version, "8.2")
        await store.loadServices()
        XCTAssertEqual(try calls(executable, command: "services").count, 3, "A successful read is cached")
    }

    @MainActor
    func testSnapshotFailureDoesNotLeaveSplashStuck() async throws {
        let (executable, backend) = try fixture()
        try fail(executable, operation: "snapshot")
        let store = SiteStore(backend: backend)
        await store.preload()
        XCTAssertFalse(store.isStarting)
        XCTAssertFalse(store.hasLoaded)
        XCTAssertEqual(store.error, "Snapshot unavailable")
        try FileManager.default.removeItem(atPath: executable.path + ".fail-snapshot")
        await store.refresh()
        XCTAssertTrue(store.hasLoaded)
    }

    @MainActor
    func testSavingPHPRefreshesAffectedVersionEvenAfterNavigatingAway() async throws {
        let (executable, backend) = try fixture()
        let store = SiteStore(backend: backend)
        await store.preload()
        let original = try XCTUnwrap(store.phpDetails)
        store.selection = "section:services"
        store.phpVersion = "8.2"
        let saved = await store.savePHP(original, values: ["memory_limit": "1G"])
        XCTAssertTrue(saved)
        store.phpVersion = "8.4"
        XCTAssertEqual(store.phpDetails?.revision, "updated")
        XCTAssertEqual(try calls(executable, command: "php-details").count, 3)
        XCTAssertEqual(try calls(executable, command: "services").count, 2, "The visible Services page is re-read")
    }

    @MainActor
    func testSavingDuringPendingReloadDoesNotCacheStaleSettings() async throws {
        let (executable, backend) = try fixture()
        let store = SiteStore(backend: backend)
        await store.preload()
        let original = try XCTUnwrap(store.phpDetails)
        XCTAssertEqual(original.version, "8.4")
        store.selection = "section:php"

        // A refresh reads the old revision, then is still running when the save lands.
        try Data().write(to: URL(fileURLWithPath: marker(executable, "slow-php-8.4")))
        let reload = Task { await store.loadPHP(force: true) }
        try await waitUntil { FileManager.default.fileExists(atPath: self.marker(executable, "read-php-8.4")) }
        try FileManager.default.removeItem(atPath: marker(executable, "slow-php-8.4"))

        let saved = await store.savePHP(original, values: ["memory_limit": "1G"])
        XCTAssertTrue(saved)
        XCTAssertEqual(store.phpDetails?.revision, "updated")
        await reload.value
        XCTAssertEqual(store.phpDetails?.revision, "updated", "The older read must not overwrite the post-save one")
        await store.loadPHP()
        XCTAssertEqual(store.phpDetails?.revision, "updated")

        XCTAssertEqual(try calls(executable, command: "services").count, 1, "A PHP save does not wait on Homebrew")
        await store.loadServices()
        XCTAssertEqual(try calls(executable, command: "services").count, 2, "Services are re-read on the next visit")
    }

    @MainActor
    func testSplashClosesBeforeOtherPHPVersionsAreWarmed() async throws {
        let (executable, backend) = try fixture()
        try Data().write(to: URL(fileURLWithPath: marker(executable, "slow-php-8.2")))
        let store = SiteStore(backend: backend)
        var finished = false
        let preload = Task {
            await store.preload()
            finished = true
        }
        try await waitUntil { !store.isStarting }
        XCTAssertFalse(finished, "The splash should not wait for non-selected PHP versions")
        XCTAssertEqual(store.phpDetails?.version, "8.4")
        XCTAssertEqual(store.services.first?.name, "nginx")

        await preload.value
        store.phpVersion = "8.2"
        XCTAssertEqual(store.phpDetails?.version, "8.2", "Warmed versions are shown from the cache")
        XCTAssertEqual(try calls(executable, command: "php-details").count, 2)
    }

    @MainActor
    func testServicesKnowWhichSitesDependOnThem() async throws {
        let (executable, backend) = try fixture()
        func site(_ domain: String, _ version: String?) -> [String: Any] {
            [
                "id": domain, "domain": domain, "root": "/p", "config_path": "/n/\(domain).conf",
                "can_switch_php": true, "php_version": version ?? NSNull(),
                "fpm": version.map { "127.0.0.1:90\($0.replacingOccurrences(of: ".", with: ""))" } ?? NSNull(),
            ]
        }
        func write(_ data: [String: Any], to name: String) throws {
            let response: [String: Any] = ["protocol_version": 1, "ok": true, "data": data]
            let url = URL(fileURLWithPath: marker(executable, name))
            try JSONSerialization.data(withJSONObject: response).write(to: url)
        }
        try write(
            [
                "sites": [site("b.test", "8.4"), site("a.test", "8.4"), site("static.test", nil)],
                "php_versions": ["8.4", "8.3"], "php_services": ["8.4": "php", "8.3": "php@8.3"],
            ], to: "snapshot")
        let rows: [[String: Any]] = [
            ["name": "nginx", "status": "started"], ["name": "php", "status": "started"],
            ["name": "php@8.3", "status": "started"], ["name": "redis", "status": "error", "exit_code": 1],
        ]
        try write(["services": rows], to: "services")
        let store = SiteStore(backend: backend)
        await store.refresh()
        let revision = store.servicesRevision
        await store.loadServices()
        XCTAssertGreaterThan(store.servicesRevision, revision, "Detail pages follow each services read")

        func service(_ name: String) throws -> Service { try XCTUnwrap(store.services.first { $0.name == name }) }
        XCTAssertEqual(
            store.sites(dependingOn: try service("nginx"))?.map(\.domain), ["a.test", "b.test", "static.test"])
        XCTAssertEqual(store.sites(dependingOn: try service("php"))?.map(\.domain), ["a.test", "b.test"])
        XCTAssertEqual(store.sites(dependingOn: try service("php@8.3"))?.count, 0)
        XCTAssertNil(store.sites(dependingOn: try service("redis")))
        XCTAssertEqual(store.usageSummary(of: try service("nginx")), "Serves 3 sites")
        XCTAssertEqual(store.usageSummary(of: try service("php")), "Used by 2 sites")
        XCTAssertEqual(store.usageSummary(of: try service("php@8.3")), "No sites use PHP 8.3")
        XCTAssertNil(store.usageSummary(of: try service("redis")))

        store.selection = "section:services"
        store.search = "zzz"
        store.showSite(try XCTUnwrap(store.sites.first { $0.domain == "a.test" }))
        XCTAssertEqual(store.selection, "a.test")
        XCTAssertEqual(store.search, "", "The chosen site is visible in the sidebar")
    }
}
