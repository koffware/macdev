import AppKit
import SwiftUI
import XCTest

@testable import MacDev

final class SplashAppearanceTests: XCTestCase {
    @MainActor
    func testArtworkIsBundledForBothAppearances() throws {
        let light = try XCTUnwrap(AppResources.bundle.url(forResource: "SplashLight", withExtension: "png"))
        let dark = try XCTUnwrap(AppResources.bundle.url(forResource: "SplashDark", withExtension: "png"))
        for url in [light, dark] {
            let image = try XCTUnwrap(NSImage(contentsOf: url))
            XCTAssertGreaterThanOrEqual(image.size.width, 1000)
            XCTAssertGreaterThanOrEqual(image.size.height, 600)
        }
        XCTAssertNotEqual(try Data(contentsOf: light), try Data(contentsOf: dark))
    }

    /// Opt-in native view captures for visual review, without launching the backend
    /// or changing the user's macOS appearance or accent preferences.
    @MainActor
    func testCaptureSplashAppearances() throws {
        guard let path = ProcessInfo.processInfo.environment["MACDEV_SPLASH_CAPTURE_DIR"] else {
            throw XCTSkip("Set MACDEV_SPLASH_CAPTURE_DIR to capture native splash views.")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for (name, scheme, appearance, accent) in [
            ("light", ColorScheme.light, NSAppearance.Name.aqua, Color.blue),
            ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua, Color.blue),
            ("dark-purple", ColorScheme.dark, NSAppearance.Name.darkAqua, Color.purple),
        ] {
            for size in [NSSize(width: 1240, height: 800), NSSize(width: 980, height: 600)] {
                let view = StartupView(status: "Loading PHP configuration…")
                    .environment(\.colorScheme, scheme)
                    .tint(accent)
                    .frame(width: size.width, height: size.height)
                let hosting = NSHostingView(rootView: view)
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = hosting
                hosting.setFrameSize(size)
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(
                    to: directory.appendingPathComponent("\(name)-\(Int(size.width))x\(Int(size.height)).png"))
            }
        }
    }
}
