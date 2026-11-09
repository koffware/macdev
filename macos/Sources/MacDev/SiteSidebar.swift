import AppKit
import MacDevCore
import SwiftUI

/// What the sites sidebar shows. Expansion is kept apart so that collapsing a
/// group does not reload rows mid-animation.
struct SiteSidebarModel: Equatable {
    struct Row: Equatable {
        let id: String
        let domain: String
        let summary: String
        let isSecure: Bool
        let health: SiteHealth?
    }

    struct Group: Equatable {
        /// nil for sites that belong to no group.
        let id: UUID?
        let name: String
        let rows: [Row]
    }

    var groups: [Group] = []
    var collapsed: Set<UUID> = []
    var searching = false

    /// Sites can only be dragged once there is a group to drag them into.
    var canGroup: Bool { groups.contains { $0.id != nil } }
}

/// The sites sidebar, built on AppKit's source-list outline view: SwiftUI's List
/// cannot drop into sections and renders drag previews in the wrong appearance.
struct SiteSidebar: NSViewRepresentable {
    @ObservedObject var store: SiteStore
    let model: SiteSidebarModel
    let prompt: (GroupPrompt) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        outline.style = .sourceList
        outline.headerView = nil
        outline.floatsGroupRows = false
        outline.allowsMultipleSelection = false
        outline.backgroundColor = .clear
        outline.indentationPerLevel = 0
        outline.autoresizesOutlineColumn = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("site"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.registerForDraggedTypes([.macDevSite, .macDevGroup])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .sourceList
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu
        outline.setAccessibilityLabel("Sites")

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.outline = outline
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(model, selection: store.selection)
    }
}

extension NSPasteboard.PasteboardType {
    static var macDevSite: Self { Self("local.macdev.site-id") }
    static var macDevGroup: Self { Self("local.macdev.group-id") }
}

extension SiteSidebar {
    /// Outline views identify rows by object identity, so nodes are cached by key
    /// and reused across reloads to keep selection and expansion stable.
    final class Node: NSObject {
        enum Kind: Equatable {
            case group(UUID?)
            case site(String)
            case placeholder(UUID)
        }

        let kind: Kind
        init(_ kind: Kind) { self.kind = kind }

        var groupID: UUID?? {
            if case .group(let id) = kind { return .some(id) }
            return nil
        }

        var siteID: String? {
            if case .site(let id) = kind { return id }
            return nil
        }
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: SiteSidebar
        weak var outline: NSOutlineView?
        private var model = SiteSidebarModel()
        private var hasLoaded = false
        private var isApplying = false
        private var cache: [String: Node] = [:]
        private var topLevel: [Node] = []
        private var children: [ObjectIdentifier: [Node]] = [:]
        private var parents: [ObjectIdentifier: Node] = [:]
        private var rows: [String: SiteSidebarModel.Row] = [:]
        private var groupInfo: [ObjectIdentifier: SiteSidebarModel.Group] = [:]

        init(_ parent: SiteSidebar) { self.parent = parent }

        private var store: SiteStore { parent.store }

        // MARK: Model

        func apply(_ next: SiteSidebarModel, selection: String?) {
            guard let outline else { return }
            isApplying = true
            defer { isApplying = false }
            if !hasLoaded || next.groups != model.groups || next.searching != model.searching {
                model = next
                rebuild()
                outline.reloadData()
                hasLoaded = true
            }
            model.collapsed = next.collapsed
            for node in topLevel {
                guard case .group(let id) = node.kind else { continue }
                let expanded = id.map { model.searching || !model.collapsed.contains($0) } ?? true
                if expanded != outline.isItemExpanded(node) {
                    if expanded { outline.expandItem(node) } else { outline.collapseItem(node) }
                    outline.reloadItem(node, reloadChildren: false)
                }
            }
            select(selection)
        }

        private func node(_ key: String, _ kind: Node.Kind) -> Node {
            if let node = cache[key], node.kind == kind { return node }
            let node = Node(kind)
            cache[key] = node
            return node
        }

        private func rebuild() {
            topLevel = []
            children = [:]
            parents = [:]
            rows = [:]
            groupInfo = [:]
            for group in model.groups {
                let header = node("group:" + (group.id?.uuidString ?? "ungrouped"), .group(group.id))
                topLevel.append(header)
                groupInfo[ObjectIdentifier(header)] = group
                var members = group.rows.map { row -> Node in
                    rows[row.id] = row
                    return node("site:" + row.id, .site(row.id))
                }
                if members.isEmpty, let id = group.id, !model.searching {
                    members = [node("placeholder:" + id.uuidString, .placeholder(id))]
                }
                children[ObjectIdentifier(header)] = members
                for member in members { parents[ObjectIdentifier(member)] = header }
            }
        }

        private func select(_ siteID: String?) {
            guard let outline else { return }
            let row = siteID.flatMap { cache["site:" + $0] }.map { outline.row(forItem: $0) } ?? -1
            if row >= 0 {
                if outline.selectedRow != row {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
            } else if outline.selectedRow >= 0 {
                outline.deselectAll(nil)
            }
        }

        private func nodes(in item: Any?) -> [Node] {
            guard let node = item as? Node else { return topLevel }
            return children[ObjectIdentifier(node)] ?? []
        }

        private func group(of node: Node) -> SiteSidebarModel.Group? {
            groupInfo[ObjectIdentifier(node)]
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            nodes(in: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            nodes(in: item)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? Node)?.groupID != nil
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            (item as? Node)?.groupID != nil
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? Node)?.siteID != nil
        }

        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            canCollapse(item)
        }

        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
            canCollapse(item)
        }

        private func canCollapse(_ item: Any) -> Bool {
            guard case .group(.some)? = (item as? Node)?.kind else { return false }
            return !model.searching
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            switch (item as? Node)?.kind {
            case .site: 38
            case .placeholder: 24
            default: 28
            }
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            switch node.kind {
            case .site(let id):
                let cell = reuse(outlineView, SiteCell.identifier) { SiteCell() }
                if let row = rows[id] { cell.configure(row) }
                return cell
            case .placeholder:
                let cell = reuse(outlineView, PlaceholderCell.identifier) { PlaceholderCell() }
                return cell
            case .group:
                let cell = reuse(outlineView, HeaderCell.identifier) { HeaderCell() }
                let info = group(of: node)
                let name = info?.name ?? ""
                let title = info?.id == nil ? (model.canGroup ? "Other Sites" : "Sites") : name
                let isCollapsed = !outlineView.isItemExpanded(node) && info?.id != nil
                cell.configure(title: title, count: isCollapsed ? info?.rows.count : nil)
                return cell
            }
        }

        private func reuse<Cell: NSView>(
            _ outline: NSOutlineView, _ identifier: NSUserInterfaceItemIdentifier, make: () -> Cell
        ) -> Cell {
            if let cell = outline.makeView(withIdentifier: identifier, owner: nil) as? Cell { return cell }
            let cell = make()
            cell.identifier = identifier
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isApplying, let outline else { return }
            let selected = (outline.item(atRow: outline.selectedRow) as? Node)?.siteID
            if let selected, selected != store.selection { store.selection = selected }
        }

        func outlineViewItemDidExpand(_ notification: Notification) { expansionChanged(notification, expanded: true) }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            expansionChanged(notification, expanded: false)
        }

        private func expansionChanged(_ notification: Notification, expanded: Bool) {
            guard !isApplying, let node = notification.userInfo?["NSObject"] as? Node,
                case .group(let id?) = node.kind
            else { return }
            if expanded { model.collapsed.remove(id) } else { model.collapsed.insert(id) }
            outline?.reloadItem(node, reloadChildren: false)
            store.setGroupExpanded(id, expanded)
        }

        // MARK: Drag and drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? Node else { return nil }
            let pasteboardItem = NSPasteboardItem()
            switch node.kind {
            case .site(let id) where model.canGroup:
                pasteboardItem.setString(id, forType: .macDevSite)
            case .group(let id?) where !model.searching:
                pasteboardItem.setString(id.uuidString, forType: .macDevGroup)
            default:
                return nil
            }
            return pasteboardItem
        }

        func outlineView(
            _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            let pasteboard = info.draggingPasteboard
            if pasteboard.string(forType: .macDevSite) != nil {
                guard let target = siteDropTarget(item as? Node, index) else { return [] }
                outlineView.setDropItem(target.node, dropChildIndex: target.index)
                return .move
            }
            if pasteboard.string(forType: .macDevGroup) != nil {
                guard let index = groupDropIndex(item as? Node, index) else { return [] }
                outlineView.setDropItem(nil, dropChildIndex: index)
                return .move
            }
            return []
        }

        /// Sites land in a group: between its rows, or on the group itself to go last.
        /// Ungrouped sites are listed alphabetically, so that section only accepts whole-section drops.
        private func siteDropTarget(_ proposed: Node?, _ index: Int) -> (node: Node, index: Int)? {
            let onItem = NSOutlineViewDropOnItemIndex
            guard let proposed else {
                // Between top-level sections: join the section above.
                guard index >= 0, !topLevel.isEmpty else { return nil }
                return (topLevel[max(index - 1, 0)], onItem)
            }
            switch proposed.kind {
            case .group(let id):
                let hasPlaceholder = nodes(in: proposed).first?.siteID == nil
                return (proposed, id == nil || hasPlaceholder ? onItem : index)
            case .site:
                guard let header = parents[ObjectIdentifier(proposed)] else { return nil }
                if group(of: header)?.id == nil { return (header, onItem) }
                return (header, nodes(in: header).firstIndex(of: proposed) ?? onItem)
            case .placeholder:
                return parents[ObjectIdentifier(proposed)].map { ($0, onItem) }
            }
        }

        /// Groups reorder among themselves, always above the ungrouped sites.
        private func groupDropIndex(_ proposed: Node?, _ index: Int) -> Int? {
            let groupCount = topLevel.filter { group(of: $0)?.id != nil }.count
            if proposed == nil, index >= 0 { return min(index, groupCount) }
            guard let proposed, proposed.groupID != nil, let position = topLevel.firstIndex(of: proposed) else {
                return nil
            }
            return min(position, groupCount)
        }

        func outlineView(
            _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int
        ) -> Bool {
            let pasteboard = info.draggingPasteboard
            if let siteID = pasteboard.string(forType: .macDevSite) {
                guard let header = item as? Node, case .group(let groupID) = header.kind else { return false }
                var anchor: String?
                if groupID != nil, index != NSOutlineViewDropOnItemIndex {
                    let siblings = nodes(in: header).compactMap(\.siteID)
                    anchor = siblings.dropFirst(index).first { $0 != siteID }
                }
                store.moveSite(siteID, toGroup: groupID, before: anchor)
                return true
            }
            if let raw = pasteboard.string(forType: .macDevGroup), let id = UUID(uuidString: raw) {
                store.moveGroup(id, to: index)
                return true
            }
            return false
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? Node
            else { return }
            switch node.kind {
            case .site(let siteID): addSiteItems(to: menu, siteID: siteID)
            case .group(let id?): addGroupItems(to: menu, id: id)
            default: break
            }
        }

        private func addSiteItems(to menu: NSMenu, siteID: String) {
            let current = store.siteGroups.group(containing: siteID)
            let submenu = NSMenu()
            for group in store.siteGroups.groups {
                let item = ActionMenuItem(group.name) { [store] in store.moveSite(siteID, toGroup: group.id) }
                item.state = group.id == current?.id ? .on : .off
                submenu.addItem(item)
            }
            if !store.siteGroups.groups.isEmpty { submenu.addItem(.separator()) }
            let prompt = parent.prompt
            submenu.addItem(ActionMenuItem("New Group…") { prompt(.create(siteID: siteID)) })
            let move = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
            move.submenu = submenu
            menu.addItem(move)
            if let current {
                menu.addItem(
                    ActionMenuItem("Remove from “\(current.name)”") { [store] in
                        store.moveSite(siteID, toGroup: nil)
                    })
            }
        }

        private func addGroupItems(to menu: NSMenu, id: UUID) {
            let groups = store.siteGroups.groups
            let prompt = parent.prompt
            menu.addItem(ActionMenuItem("Rename Group…") { prompt(.rename(id)) })
            let moveUp = ActionMenuItem("Move Up") { [store] in store.shiftGroup(id, by: -1) }
            moveUp.isEnabled = groups.first?.id != id
            let moveDown = ActionMenuItem("Move Down") { [store] in store.shiftGroup(id, by: 1) }
            moveDown.isEnabled = groups.last?.id != id
            menu.addItem(moveUp)
            menu.addItem(moveDown)
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Delete Group") { [store] in store.deleteGroup(id) })
        }
    }
}

/// A menu item that runs a closure; it enables itself unless `isEnabled` is cleared.
private final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor @Sendable () -> Void

    init(_ title: String, handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not used from Interface Builder") }

    // Menu actions are always delivered on the main thread.
    @objc private func run() {
        let handler = handler
        MainActor.assumeIsolated { handler() }
    }
}

// MARK: - Cells

private final class SiteCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SiteCell")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let dot = NSView()

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for view in [icon, text, dot] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = title
        imageView = icon
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 6),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ row: SiteSidebarModel.Row) {
        title.stringValue = row.domain
        subtitle.stringValue = row.summary
        icon.image = NSImage(
            systemSymbolName: row.isSecure ? "lock.fill" : "lock.open",
            accessibilityDescription: row.isSecure ? "HTTPS" : "HTTP only")
        dot.isHidden = row.health == nil
        dot.layer?.backgroundColor = row.health.map { NSColor($0.color).cgColor }
        toolTip = [row.domain, row.isSecure ? "HTTPS" : "HTTP only", row.health?.message].compactMap { $0 }
            .joined(separator: " · ")
        setAccessibilityLabel(row.domain)
        setAccessibilityValue(
            [row.isSecure ? "HTTPS" : "HTTP only", row.summary, row.health?.message].compactMap { $0 }
                .joined(separator: ", "))
        updateColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    private func updateColors() {
        let emphasized = backgroundStyle == .emphasized
        icon.contentTintColor = emphasized ? .alternateSelectedControlTextColor : .controlAccentColor
        subtitle.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }
}

private final class HeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("HeaderCell")
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        title.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.textColor = .tertiaryLabelColor
        for view in [title, count] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = title
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            title.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            // Leaves room for the source list's Show/Hide button.
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            count.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(title value: String, count total: Int?) {
        title.stringValue = value
        count.stringValue = total.map(String.init) ?? ""
        toolTip = value
    }
}

private final class PlaceholderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PlaceholderCell")

    init() {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: "Drag sites here")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}
