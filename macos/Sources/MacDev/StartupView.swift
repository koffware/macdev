import SwiftUI

/// Uses the system appearance and accent; the illustration is the brand artwork.
struct StartupView: View {
    let status: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 660
            VStack(spacing: 0) {
                Spacer(minLength: 12)
                Image(nsImage: colorScheme == .dark ? SplashArtwork.dark : SplashArtwork.light)
                    .resizable()
                    .scaledToFit()
                    .frame(width: compact ? 420 : 570, height: compact ? 250 : 340)
                    .padding(.bottom, compact ? -16 : -20)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("MacDev")
                        .font(.system(size: compact ? 48 : 72, weight: .semibold))
                        .tracking(-1.5)
                        .foregroundStyle(.primary)
                    Text("A good place to build.")
                        .font(.system(size: compact ? 20 : 24))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(AccentLoadingStyle())
                        .frame(width: compact ? 320 : 380)
                        .accessibilityLabel("Preparing your workspace")
                    Text(status)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(height: 34, alignment: .top)
                        .frame(maxWidth: 500)
                        .accessibilityLabel(status)
                }
                .padding(.top, compact ? 26 : 34)

                Spacer(minLength: 24)
                Text("Your local development workspace")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, compact ? 24 : 36)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// AppKit's indeterminate bar does not honor SwiftUI's tint in every appearance.
/// Keep an indeterminate animation while resolving the accent from macOS.
private struct AccentLoadingStyle: ProgressViewStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving = false

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            Capsule().fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule().fill(.tint)
                        .frame(width: geometry.size.width * 0.28)
                        .offset(x: geometry.size.width * (reduceMotion ? 0.36 : (moving ? 0.72 : 0)))
                }
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: moving
                )
                .onAppear { moving = true }
        }
        .frame(height: 5)
    }
}

private enum SplashArtwork {
    static let light = load("SplashLight")
    static let dark = load("SplashDark")

    private static func load(_ name: String) -> NSImage {
        guard let url = AppResources.bundle.url(forResource: name, withExtension: "png"),
            let image = NSImage(contentsOf: url)
        else {
            preconditionFailure("Missing bundled splash artwork: \(name)")
        }
        return image
    }
}

enum AppResources {
    static let bundle: Bundle = {
        // SwiftPM's generated accessor differs between build systems. The app
        // bundle always keeps its assets in Contents/Resources for distribution.
        if let resources = Bundle.main.resourceURL,
            let embedded = Bundle(url: resources.appendingPathComponent("MacDev_MacDev.bundle"))
        {
            return embedded
        }
        return Bundle.module
    }()
}
