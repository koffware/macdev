import AppKit
import SwiftUI
import XCTest

@testable import MacDev

final class SidebarWidthTests: XCTestCase {
    @MainActor
    func testNativeDividerCannotResizeSidebar() async throws {
        let sidebarWidth: CGFloat = 240
        let hosting = NSHostingController(
            rootView:
                NavigationSplitView(columnVisibility: .constant(.all)) {
                    List { Text("Sites") }
                        .frame(width: sidebarWidth)
                        .navigationSplitViewColumnWidth(min: sidebarWidth, ideal: sidebarWidth, max: sidebarWidth)
                        .background(SidebarWidthLock(width: sidebarWidth))
                } detail: {
                    Text("Workspace").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = hosting
        // Give SwiftUI's representable its native parent hierarchy. No backend
        // or real Homebrew/nginx configuration participates in this layout test.
        for _ in 0..<20 {
            hosting.view.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        let split = try XCTUnwrap(findSplitView(in: hosting.view))
        let controller = try XCTUnwrap(split.delegate as? NSSplitViewController)
        let item = try XCTUnwrap(controller.splitViewItems.first)
        XCTAssertEqual(item.minimumThickness, sidebarWidth)
        XCTAssertEqual(item.maximumThickness, sidebarWidth)
        XCTAssertFalse(item.canCollapse)
        XCTAssertFalse(item.canCollapseFromWindowResize)

        for proposedPosition: CGFloat in [100, 400, 600] {
            split.setPosition(proposedPosition, ofDividerAt: 0)
            hosting.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(try XCTUnwrap(split.arrangedSubviews.first).frame.width, sidebarWidth, accuracy: 0.5)
        }
        for windowWidth: CGFloat in [980, 1600] {
            window.setContentSize(NSSize(width: windowWidth, height: 800))
            hosting.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(try XCTUnwrap(split.arrangedSubviews.first).frame.width, sidebarWidth, accuracy: 0.5)
        }
    }

    @MainActor
    private func findSplitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for child in view.subviews {
            if let split = findSplitView(in: child) { return split }
        }
        return nil
    }
}
