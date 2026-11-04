import AppKit
import SwiftUI

/// SwiftUI's column preferences can leave the underlying divider draggable.
/// Constrain its native pane without replacing SwiftUI's split-view delegate.
struct SidebarWidthLock: NSViewRepresentable {
    let width: CGFloat

    func makeNSView(context: Context) -> LockView { LockView(width: width) }

    func updateNSView(_ view: LockView, context: Context) {
        view.width = width
        view.scheduleLock()
    }

    static func dismantleNSView(_ view: LockView, coordinator: ()) {
        view.stopLocking()
    }

    final class LockView: NSView {
        var width: CGFloat
        private var widthConstraint: NSLayoutConstraint?
        private var scheduled = false
        private var isActive = true

        init(width: CGFloat) {
            self.width = width
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleLock()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleLock()
        }

        override func layout() {
            super.layout()
            applyLock()
        }

        func scheduleLock() {
            guard isActive, !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                scheduled = false
                applyLock()
            }
        }

        func stopLocking() {
            isActive = false
            removeLock()
        }

        private func removeLock() {
            widthConstraint?.isActive = false
            widthConstraint = nil
        }

        private func applyLock() {
            guard isActive else { return }
            var ancestor = superview
            while let view = ancestor {
                if let split = view as? NSSplitView, split.isVertical,
                    let pane = split.arrangedSubviews.first, isDescendant(of: pane),
                    let controller = split.delegate as? NSSplitViewController,
                    let item = controller.splitViewItems.first
                {
                    if item.minimumThickness != width { item.minimumThickness = width }
                    if item.maximumThickness != width { item.maximumThickness = width }
                    if item.canCollapse { item.canCollapse = false }
                    if item.canCollapseFromWindowResize { item.canCollapseFromWindowResize = false }
                    if item.holdingPriority != .required { item.holdingPriority = .required }

                    if widthConstraint?.firstItem as? NSView !== pane {
                        removeLock()
                        let constraint = pane.widthAnchor.constraint(equalToConstant: width)
                        constraint.identifier = "MacDev.FixedSidebarWidth"
                        constraint.isActive = true
                        widthConstraint = constraint
                    } else if widthConstraint?.constant != width {
                        widthConstraint?.constant = width
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
