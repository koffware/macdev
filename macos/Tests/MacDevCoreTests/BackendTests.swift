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
}
