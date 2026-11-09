import Foundation
import MacDevCore

/// A user-defined sidebar group. Groups live in the app's preferences only:
/// nginx configuration remains the single source of truth for sites.
struct SiteGroup: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var siteIDs: [String] = []
    var isExpanded = true
}

struct SidebarSection {
    /// nil for sites that belong to no group.
    let group: SiteGroup?
    let sites: [Site]
}

/// Pure group operations, kept separate from persistence so they are easy to test.
struct SiteGroups: Equatable, Sendable {
    private(set) var groups: [SiteGroup]

    init(_ groups: [SiteGroup] = []) { self.groups = groups }

    func group(containing siteID: String) -> SiteGroup? {
        groups.first { $0.siteIDs.contains(siteID) }
    }

    func isAvailable(_ name: String, excluding id: UUID? = nil) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty
            && !groups.contains { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    @discardableResult mutating func create(named name: String, containing siteID: String? = nil) -> UUID? {
        guard isAvailable(name) else { return nil }
        let group = SiteGroup(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        groups.append(group)
        if let siteID { move(siteID, to: group.id) }
        return group.id
    }

    mutating func rename(_ id: UUID, to name: String) {
        guard isAvailable(name, excluding: id), let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func delete(_ id: UUID) {
        groups.removeAll { $0.id == id }
    }

    /// Moves a site into a group, or out of every group when `groupID` is nil.
    /// It is placed before `anchor` when that site is in the group, otherwise last.
    mutating func move(_ siteID: String, to groupID: UUID?, before anchor: String? = nil) {
        for index in groups.indices { groups[index].siteIDs.removeAll { $0 == siteID } }
        guard let groupID, let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let position = anchor.flatMap { groups[index].siteIDs.firstIndex(of: $0) } ?? groups[index].siteIDs.endIndex
        groups[index].siteIDs.insert(siteID, at: position)
    }

    /// Keeps membership when a site's configuration is renamed.
    mutating func replace(_ oldID: String, with newID: String) {
        for index in groups.indices {
            groups[index].siteIDs = groups[index].siteIDs.map { $0 == oldID ? newID : $0 }
        }
    }

    mutating func shift(_ id: UUID, by offset: Int) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard groups.indices.contains(destination) else { return }
        groups.swapAt(index, destination)
    }

    /// Moves a group to `index`, counted in the order before the move (as AppKit drops report it).
    mutating func moveGroup(_ id: UUID, to index: Int) {
        guard let source = groups.firstIndex(where: { $0.id == id }) else { return }
        let group = groups.remove(at: source)
        let destination = index > source ? index - 1 : index
        groups.insert(group, at: min(max(destination, 0), groups.count))
    }

    mutating func setExpanded(_ id: UUID, _ isExpanded: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].isExpanded = isExpanded
    }

    /// Groups in their saved order with members in their arranged order, then
    /// ungrouped sites in the order given. While searching, groups without matches are hidden.
    func sections(for sites: [Site], searching: Bool) -> [SidebarSection] {
        let byID = Dictionary(sites.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var grouped = Set<String>()
        var sections: [SidebarSection] = []
        for group in groups {
            let members = group.siteIDs.compactMap { grouped.contains($0) ? nil : byID[$0] }
            grouped.formUnion(members.map(\.id))
            if !searching || !members.isEmpty { sections.append(SidebarSection(group: group, sites: members)) }
        }
        let rest = sites.filter { !grouped.contains($0.id) }
        if !rest.isEmpty || groups.isEmpty { sections.append(SidebarSection(group: nil, sites: rest)) }
        return sections
    }
}
