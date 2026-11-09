import Foundation
import XCTest

@testable import MacDevCore

final class BackendTests: XCTestCase {
    func testDecodesRealProtocolAndNullableFields() throws {
        let json =
            #"{"protocol_version":1,"ok":true,"data":{"sites":[{"id":"app.test","domain":"app.test","root":"/tmp/my project","php_version":null,"fpm":null,"certificate":null,"config_path":"/tmp/app.test.conf","can_switch_php":false}],"php_versions":["8.4"]}}"#
        let result = try JSONDecoder().decode(Response<Snapshot>.self, from: Data(json.utf8)).value(exitCode: 0)
        XCTAssertEqual(result.phpVersions, ["8.4"])
        XCTAssertNil(result.sites[0].phpVersion)
        XCTAssertEqual(result.sites[0].url?.absoluteString, "http://app.test")
    }

    private func site(_ overrides: [String: Any] = [:]) throws -> Site {
        var fields: [String: Any] = [
            "id": "app.test", "domain": "app.test", "root": "/p/app/public", "fpm": "127.0.0.1:9084",
            "php_version": "8.4", "certificate": "/c.pem", "config_path": "/n/app.test.conf",
            "can_switch_php": true,
        ]
        fields.merge(overrides) { $1 }
        return try JSONDecoder().decode(Site.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func services(_ statuses: [String: String]) throws -> [Service] {
        let rows = statuses.map { ["name": $0.key, "status": $0.value] }
        return try JSONDecoder().decode([Service].self, from: JSONSerialization.data(withJSONObject: rows))
    }

    func testSiteSummaryShowsFrameworkAndPHP() throws {
        let symfony = try site(["project_root": "/p/app", "framework": "Symfony", "framework_version": "8.1"])
        XCTAssertEqual(symfony.summary, "Symfony 8.1 · PHP 8.4")
        XCTAssertEqual(symfony.projectRoot, "/p/app")
        XCTAssertTrue(symfony.isSecure)
        XCTAssertEqual(try site().summary, "PHP 8.4")
        XCTAssertEqual(try site(["fpm": NSNull(), "php_version": NSNull()]).summary, "Static")
        XCTAssertFalse(try site(["certificate": NSNull()]).isSecure)
    }

    func testSiteHealth() throws {
        let healthy = try site(["root_exists": true])
        XCTAssertNil(healthy.health(services: [], phpService: "php@8.4"))
        let running = try services(["nginx": "started", "php@8.4": "started"])
        XCTAssertEqual(healthy.health(services: running, phpService: "php@8.4"), .ok)
        let stopped = try services(["nginx": "started", "php@8.4": "none"])
        XCTAssertEqual(healthy.health(services: stopped, phpService: "php@8.4"), .warning("PHP 8.4 is not running"))
        XCTAssertEqual(
            healthy.health(services: try services(["nginx": "stopped"]), phpService: nil),
            .problem("nginx is not running"))
        XCTAssertEqual(
            try site(["root_exists": false]).health(services: running, phpService: "php@8.4"),
            .problem("Project folder is missing"))
    }

    func testCertificateHealth() throws {
        let now = try Date("2026-11-07T12:00:00Z", strategy: .iso8601)
        XCTAssertNil(try site(["certificate": NSNull()]).certificateHealth(now: now))
        XCTAssertEqual(try site().certificateHealth(now: now), .ok)
        XCTAssertEqual(try site(["certificate_expires": "2028-08-15T17:08:12Z"]).certificateHealth(now: now), .ok)
        XCTAssertEqual(
            try site(["certificate_expires": "2026-11-17T12:00:00Z"]).certificateHealth(now: now),
            .warning("Certificate expires in 10 days"))
        XCTAssertEqual(
            try site(["certificate_expires": "2026-11-07T18:00:00Z"]).certificateHealth(now: now),
            .warning("Certificate expires today"))
        guard
            case .problem(let expired) = try site(["certificate_expires": "2026-11-01T00:00:00Z"]).certificateHealth(
                now: now)
        else {
            XCTFail("An expired certificate is a problem")
            return
        }
        XCTAssertTrue(expired.hasPrefix("Certificate expired on"))
        XCTAssertEqual(
            try site(["certificate_issue": "Certificate does not cover app.test"]).certificateHealth(now: now),
            .warning("Certificate does not cover app.test"))
        XCTAssertEqual(
            try site(["certificate_issue": "Certificate key file is missing"]).certificateHealth(now: now),
            .problem("Certificate key file is missing"))
    }

    func testHealthIncludesCertificateAndRequirement() throws {
        let now = try Date("2026-11-07T12:00:00Z", strategy: .iso8601)
        let running = try services(["nginx": "started", "php@8.4": "started"])
        let missing = try site([
            "root_exists": true, "certificate_issue": "Certificate file is missing · nginx cannot reload",
        ])
        // Certificate files are checked before service status is known.
        XCTAssertEqual(
            missing.health(services: [], phpService: "php@8.4", now: now),
            .problem("Certificate file is missing · nginx cannot reload"))
        let outdated = try site([
            "root_exists": true, "php_requirement": ">=8.5", "php_supported_versions": ["8.5"],
            "certificate_expires": "2026-11-10T00:00:00Z",
        ])
        XCTAssertFalse(try XCTUnwrap(outdated.requirementMet))
        XCTAssertTrue(try XCTUnwrap(outdated.supports(phpVersion: "8.5")))
        XCTAssertEqual(
            outdated.health(services: running, phpService: "php@8.4", now: now), .warning("Project requires PHP >=8.5"))
        // Known configuration problems show before service status loads.
        XCTAssertEqual(
            outdated.health(services: [], phpService: "php@8.4", now: now), .warning("Project requires PHP >=8.5"))
        let stopped = try services(["nginx": "started", "php@8.4": "none"])
        XCTAssertEqual(
            outdated.health(services: stopped, phpService: "php@8.4", now: now), .warning("PHP 8.4 is not running"))
        let unknown = try site(["root_exists": true, "php_requirement": "garbage"])
        XCTAssertNil(unknown.requirementMet)
        XCTAssertEqual(unknown.health(services: running, phpService: "php@8.4", now: now), .ok)
        let expiring = try site(["root_exists": true, "certificate_expires": "2026-11-10T00:00:00Z"])
        XCTAssertEqual(
            expiring.health(services: running, phpService: "php@8.4", now: now),
            .warning("Certificate expires in 2 days"))
        XCTAssertNil(try site(["fpm": NSNull(), "php_version": NSNull(), "php_supported_versions": []]).requirementMet)
    }

    func testDecodesSiteLogs() throws {
        let logged = try site([
            "logs": [
                ["kind": "error", "path": "/l/e.log", "exists": true, "size": 12, "modified": "2026-11-04T16:15:21Z"],
                ["kind": "access", "path": "/l/a.log", "exists": false, "size": NSNull(), "modified": NSNull()],
            ]
        ])
        XCTAssertEqual(logged.logs?.map(\.title), ["Error log", "Access log"])
        XCTAssertNotNil(logged.logs?.first?.modifiedDate)
        XCTAssertNil(logged.logs?.last?.size)
    }

    func testConfigValues() {
        XCTAssertEqual(ConfigValue.bytes("50m"), 50 * 1024 * 1024)
        XCTAssertEqual(ConfigValue.bytes("2M"), 2 * 1024 * 1024)
        XCTAssertEqual(ConfigValue.bytes("1G"), 1024 * 1024 * 1024)
        XCTAssertEqual(ConfigValue.bytes("4096"), 4096)
        XCTAssertEqual(ConfigValue.bytes("0"), 0)
        XCTAssertNil(ConfigValue.bytes("lots"))
        XCTAssertNil(ConfigValue.bytes(nil))
        XCTAssertEqual(ConfigValue.seconds("60s"), 60)
        XCTAssertEqual(ConfigValue.seconds("2m"), 120)
        XCTAssertEqual(ConfigValue.seconds("1h"), 3600)
        XCTAssertEqual(ConfigValue.seconds("30"), 30)
        XCTAssertEqual(ConfigValue.seconds("1500ms"), 1)
        XCTAssertEqual(ConfigValue.duration(60), "1 min")
        XCTAssertEqual(ConfigValue.duration(90), "90 s")
        XCTAssertEqual(ConfigValue.duration(0), "No limit")
    }

    func testRequestLimitWarnings() throws {
        let site = try site(["client_max_body_size": "50m", "fastcgi_read_timeout": "60s"])
        let defaults = RequestLimits(
            site: site,
            phpSettings: ["upload_max_filesize": "2M", "post_max_size": "8M", "max_execution_time": "30"])
        XCTAssertEqual(defaults.phpUpload, 2 * 1024 * 1024)
        XCTAssertEqual(
            defaults.uploadWarning?.hasPrefix("nginx accepts up to 50 MB, but PHP drops files over 2 MB"), true)
        XCTAssertNil(defaults.timeoutWarning)
        let generous = RequestLimits(
            site: site,
            phpSettings: ["upload_max_filesize": "512M", "post_max_size": "512M", "max_execution_time": "0"])
        XCTAssertNil(generous.uploadWarning)
        XCTAssertEqual(
            generous.timeoutWarning?.hasPrefix("nginx stops waiting for PHP after 1 min, but PHP has no time limit"),
            true)
        let inverted = RequestLimits(site: site, phpSettings: ["upload_max_filesize": "64M", "post_max_size": "8M"])
        XCTAssertEqual(
            inverted.uploadWarning?.hasPrefix("post_max_size (8 MB) is smaller than upload_max_filesize (64 MB)"), true)
        let unknown = RequestLimits(site: site, phpSettings: nil)
        XCTAssertNil(unknown.phpUpload)
        XCTAssertNil(unknown.uploadWarning)
        XCTAssertNil(unknown.timeoutWarning)
        // Without client_max_body_size, nginx's 1 MB default applies.
        let unset = RequestLimits(
            site: try self.site(), phpSettings: ["upload_max_filesize": "2M", "post_max_size": "8M"])
        XCTAssertNil(unset.uploadWarning)
    }

    func testServiceStatusTitles() throws {
        let json =
            #"[{"name":"nginx","status":"started"},{"name":"php","status":"none"},{"name":"db","status":"error","exit_code":1}]"#
        let services = try JSONDecoder().decode([Service].self, from: Data(json.utf8))
        XCTAssertEqual(services.map(\.statusTitle), ["Running", "Not started", "Error"])
        XCTAssertEqual(services.map(\.isRegistered), [true, false, true])
        XCTAssertTrue(services[2].hasError)
    }

    func testPreservesStructuredFailureWithNonzeroExit() throws {
        let json = #"{"protocol_version":1,"ok":false,"error":"Configuration restored"}"#
        let response = try JSONDecoder().decode(Response<Snapshot>.self, from: Data(json.utf8))
        XCTAssertThrowsError(try response.value(exitCode: 1)) { error in
            XCTAssertEqual(error.localizedDescription, "Configuration restored")
        }
    }

    func testRefusesUnsupportedProtocol() throws {
        let json = #"{"protocol_version":2,"ok":true,"data":{"changed":true}}"#
        let response = try JSONDecoder().decode(Response<PHPChange>.self, from: Data(json.utf8))
        XCTAssertThrowsError(try response.value(exitCode: 0))
    }

    func testFinderLaunchEnvironmentIncludesHomebrewAndSource() throws {
        let environment = Backend.environment(
            sourceDirectory: URL(fileURLWithPath: "/tmp/source"), inherited: ["PATH": "/custom/bin"])
        let path = try XCTUnwrap(environment["PATH"])
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.contains("/usr/local/bin"))
        XCTAssertTrue(path.contains("/custom/bin"))
        XCTAssertEqual(environment["PYTHONPATH"], "/tmp/source")
        XCTAssertEqual(environment["PYTHONDONTWRITEBYTECODE"], "1")
    }

    func testProcessCapturesBothStreamsWithoutShellInterpolation() throws {
        let directory = FileManager.default.temporaryDirectory
        let result = try Backend.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s' \"$1\"; printf diagnostic >&2; exit 7", "test", "literal $(touch never)"],
            sourceDirectory: directory)
        XCTAssertEqual(String(data: result.output, encoding: .utf8), "literal $(touch never)")
        XCTAssertEqual(String(data: result.error, encoding: .utf8), "diagnostic")
        XCTAssertEqual(result.exitCode, 7)
    }

    func testMissingInterpreterProducesActionableError() {
        XCTAssertThrowsError(
            try Backend.run(
                executable: "/missing/python", arguments: [], sourceDirectory: FileManager.default.temporaryDirectory)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Settings"))
        }
    }

    func testDecodesManagementCapabilitiesAndRevision() throws {
        let json =
            #"{"id":"app.test","domain":"app.test","root":"/tmp/public","php_version":"8.4","fpm":"127.0.0.1:9084","certificate":null,"config_path":"/tmp/app.test.conf","can_switch_php":true,"revision":"abc123","can_edit":true,"can_delete":true}"#
        let site = try JSONDecoder().decode(Site.self, from: Data(json.utf8))
        XCTAssertEqual(site.revision, "abc123")
        XCTAssertTrue(try XCTUnwrap(site.canEdit))
        XCTAssertTrue(try XCTUnwrap(site.canDelete))
    }

    func testDecodesFPMSettingsAndExtensionProvenance() throws {
        let json =
            #"{"version":"8.4","ini_path":"/etc/php/8.4/php.ini","scan_directory":"/etc/php/8.4/conf.d","settings":{"memory_limit":"512M"},"extensions":[{"id":"redis","name":"redis","enabled":true,"loaded":false,"builtin":false,"version":"6.0.0","can_toggle":true,"can_remove":true,"sources":["/etc/php/8.4/conf.d/redis.ini"]}],"revision":"abc123","service":"php@8.4","installer_available":true,"diagnostics":"Startup warning"}"#
        let details = try JSONDecoder().decode(PHPDetails.self, from: Data(json.utf8))
        XCTAssertEqual(details.settings["memory_limit"], "512M")
        XCTAssertTrue(details.extensions[0].enabled)
        XCTAssertFalse(details.extensions[0].loaded)
        XCTAssertTrue(details.extensions[0].canRemove)
        XCTAssertEqual(details.service, "php@8.4")
        XCTAssertNil(details.release)
    }

    func testDecodesRuntimeFactsAndTerminalVersion() throws {
        let json =
            #"{"version":"8.4","release":"8.4.7","binary":"/opt/homebrew/opt/php@8.4/bin/php","fpm_listen":"127.0.0.1:9084","ini_path":"/etc/php.ini","scan_directory":"/etc/conf.d","settings":{},"extensions":[{"id":"opcache","name":"opcache","enabled":true,"loaded":true,"builtin":true,"can_toggle":false,"can_remove":false,"sources":[]}],"revision":"abc","service":"php@8.4","installer_available":false}"#
        let details = try JSONDecoder().decode(PHPDetails.self, from: Data(json.utf8))
        XCTAssertEqual(details.release, "8.4.7")
        XCTAssertEqual(details.fpmListen, "127.0.0.1:9084")
        XCTAssertTrue(details.extensions[0].isActive)
        let snapshot = try JSONDecoder().decode(
            Snapshot.self, from: Data(#"{"sites":[],"php_versions":["8.4"],"php_cli_version":"8.4"}"#.utf8))
        XCTAssertEqual(snapshot.phpCLIVersion, "8.4")
    }

    func testDecodesServiceErrorsWithoutCallingThemRunning() throws {
        let json = #"{"services":[{"name":"nginx","status":"error","user":"test","exit_code":2}]}"#
        let result = try JSONDecoder().decode(ServiceList.self, from: Data(json.utf8))
        XCTAssertFalse(result.services[0].isRunning)
        XCTAssertEqual(result.services[0].exitCode, 2)
    }

    func testDecodesSeparateINIMigrationAction() throws {
        let json =
            #"{"id":"redis","name":"redis","enabled":true,"loaded":true,"builtin":false,"version":"6.0.0","package":"redis","can_toggle":true,"can_remove":true,"sources":["/etc/php/8.4/php.ini"],"ini_path":null,"can_separate_ini":true}"#
        let item = try JSONDecoder().decode(PHPExtension.self, from: Data(json.utf8))
        XCTAssertTrue(try XCTUnwrap(item.canSeparateIni))
        XCTAssertNil(item.iniPath)
    }

    func testDecodesServiceDetailsAndSummarisesPorts() throws {
        let json =
            #"{"name":"redis","status":"started","pid":1702,"exit_code":null,"user":"me","runs_as_root":false,"command":"/opt/homebrew/opt/redis/bin/redis-server","plist":"/Users/me/Library/LaunchAgents/homebrew.mxcl.redis.plist","working_directory":"/opt/homebrew/var","uptime":957398,"memory":2654208,"process_count":3,"ports":[{"protocol":"UDP","host":"*","port":53},{"protocol":"TCP","host":"127.0.0.1","port":6379},{"protocol":"TCP","host":"::1","port":6379},{"protocol":"TCP","host":"0.0.0.0","port":8080},{"protocol":"TCP","host":"10.0.0.2","port":9000},{"protocol":"TCP","host":"fe80::1","port":9000}],"logs":[{"kind":"output","title":"Log","path":"/opt/homebrew/var/log/redis.log","exists":true,"size":98087,"modified":"2026-11-04T10:31:14Z"}],"can_check":false,"explanation":null,"terminal_command":null}"#
        let details = try JSONDecoder().decode(ServiceDetails.self, from: Data(json.utf8))
        XCTAssertEqual(
            details.portSummary, "*:53 (UDP), localhost:6379, *:8080, 10.0.0.2:9000, [fe80::1]:9000")
        XCTAssertEqual(details.uptimeSummary, "11 days, 2 hours")
        XCTAssertTrue(try XCTUnwrap(details.memorySummary).hasSuffix("· 3 processes"))
        XCTAssertEqual(details.logs[0].title, "Log")
        XCTAssertNotNil(details.logs[0].modifiedDate)
    }

    func testFailedServiceDetailsHaveNoProcessFacts() throws {
        let json =
            #"{"name":"dnsmasq","status":"error","pid":null,"exit_code":2,"user":"me","runs_as_root":false,"command":null,"plist":null,"working_directory":null,"uptime":null,"memory":null,"process_count":0,"ports":null,"logs":[],"can_check":true,"explanation":"Port 53 needs root.","terminal_command":"sudo brew services start dnsmasq"}"#
        let details = try JSONDecoder().decode(ServiceDetails.self, from: Data(json.utf8))
        XCTAssertNil(details.portSummary)
        XCTAssertNil(details.uptimeSummary)
        XCTAssertNil(details.memorySummary)
        XCTAssertEqual(details.terminalCommand, "sudo brew services start dnsmasq")
        let empty = try JSONDecoder().decode(
            ServiceDetails.self, from: Data(json.replacingOccurrences(of: #""ports":null"#, with: #""ports":[]"#).utf8))
        XCTAssertNil(empty.portSummary)
    }
}
