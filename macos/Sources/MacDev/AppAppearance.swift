import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case auto, dark, light

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: nil
        case .dark: .dark
        case .light: .light
        }
    }
}
