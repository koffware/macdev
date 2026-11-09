import Foundation
import MacDevCore
import XCTest

@testable import MacDev

final class SiteGroupsTests: XCTestCase {
    private func sites(_ ids: [String]) throws -> [Site] {
        let rows = ids.map { ["id": $0, "domain": $0, "config_path": "/n/\($0).conf", "can_switch_php": false] }
        return try JSONDecoder().decode([Site].self, from: JSONSerialization.data(withJSONObject: rows))
    }

    func testSitesBelongToOneGroupAndUngroupedComeLast() throws {
        var groups = SiteGroups()
        let work = try XCTUnwrap(groups.create(named: "Work", containing: "a.test"))
        let home = try XCTUnwrap(groups.create(named: " Home ", containing: "b.test"))
        groups.move("a.test", to: home)
        XCTAssertEqual(groups.group(containing: "a.test")?.name, "Home")
        let sections = groups.sections(for: try sites(["a.test", "b.test", "c.test"]), searching: false)
        XCTAssertEqual(sections.map { $0.group?.name }, ["Work", "Home", nil])
        XCTAssertEqual(sections.map { $0.sites.map(\.id) }, [[], ["b.test", "a.test"], ["c.test"]])
        groups.delete(work)
        groups.move("a.test", to: nil)
        XCTAssertNil(groups.group(containing: "a.test"))
    }

    func testNamesAreTrimmedAndUnique() throws {
        var groups = SiteGroups()
        let id = try XCTUnwrap(groups.create(named: "Clients"))
        XCTAssertNil(groups.create(named: "clients "))
        XCTAssertNil(groups.create(named: "   "))
        XCTAssertTrue(groups.isAvailable("Clients", excluding: id))
        groups.rename(id, to: "Agency")
        XCTAssertEqual(groups.groups.map(\.name), ["Agency"])
    }

    func testSearchHidesEmptyGroupsAndRenameKeepsMembership() throws {
        var groups = SiteGroups()
        let first = try XCTUnwrap(groups.create(named: "First", containing: "old.test"))
        groups.create(named: "Second")
        groups.replace("old.test", with: "new.test")
        XCTAssertEqual(groups.group(containing: "new.test")?.id, first)
        let matches = groups.sections(for: try sites(["new.test"]), searching: true)
        XCTAssertEqual(matches.map { $0.group?.name }, ["First"])
        groups.shift(first, by: 1)
        XCTAssertEqual(groups.groups.map(\.name), ["Second", "First"])
        groups.shift(first, by: 1)
        XCTAssertEqual(groups.groups.map(\.name), ["Second", "First"])
    }

    func testDropPositionSetsManualOrderInsideGroup() throws {
        var groups = SiteGroups()
        let group = try XCTUnwrap(groups.create(named: "Work"))
        groups.move("b.test", to: group)
        groups.move("c.test", to: group)
        groups.move("a.test", to: group, before: "c.test")
        XCTAssertEqual(groups.groups[0].siteIDs, ["b.test", "a.test", "c.test"])
        // An anchor outside the group appends; moving within the group reorders.
        groups.move("c.test", to: group, before: "elsewhere.test")
        groups.move("c.test", to: group, before: "b.test")
        XCTAssertEqual(groups.groups[0].siteIDs, ["c.test", "b.test", "a.test"])
        let section = try XCTUnwrap(
            groups.sections(for: try sites(["a.test", "b.test", "c.test"]), searching: false).first)
        XCTAssertEqual(section.sites.map(\.id), ["c.test", "b.test", "a.test"])
    }

    func testGroupMovesUseIndexBeforeTheMove() throws {
        var groups = SiteGroups()
        let first = try XCTUnwrap(groups.create(named: "A"))
        groups.create(named: "B")
        let third = try XCTUnwrap(groups.create(named: "C"))
        groups.moveGroup(first, to: 3)
        XCTAssertEqual(groups.groups.map(\.name), ["B", "C", "A"])
        groups.moveGroup(third, to: 0)
        XCTAssertEqual(groups.groups.map(\.name), ["C", "B", "A"])
        groups.moveGroup(third, to: 1)
        XCTAssertEqual(groups.groups.map(\.name), ["C", "B", "A"], "Dropping in place changes nothing")
    }

    @MainActor func testSidebarModelListsGroupsThenUngrouped() throws {
        let suite = "MacDevTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let store = SiteStore(defaults: defaults)
        let work = try XCTUnwrap(store.createGroup(named: "Work"))
        store.setGroupExpanded(work, false)
        let model = store.sidebarModel
        XCTAssertEqual(model.groups.map(\.id), [work])
        XCTAssertEqual(model.collapsed, [work])
        XCTAssertTrue(model.canGroup)
    }

    @MainActor func testStoreIgnoresDroppedTextThatIsNotASite() throws {
        let suite = "MacDevTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let store = SiteStore(defaults: defaults)
        let group = try XCTUnwrap(store.createGroup(named: "Work"))
        store.moveSite("some dragged text", toGroup: group)
        XCTAssertEqual(store.siteGroups.groups.first?.siteIDs, [])
    }

    @MainActor func testStorePersistsGroups() throws {
        let suite = "MacDevTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let store = SiteStore(defaults: defaults)
        let id = try XCTUnwrap(store.createGroup(named: "Polavis", containing: "ama_b.polavis.test"))
        store.setGroupExpanded(id, false)
        let reopened = SiteStore(defaults: defaults)
        XCTAssertEqual(reopened.siteGroups.groups.map(\.name), ["Polavis"])
        XCTAssertEqual(reopened.siteGroups.groups.first?.siteIDs, ["ama_b.polavis.test"])
        XCTAssertEqual(reopened.siteGroups.groups.first?.isExpanded, false)
    }
}
