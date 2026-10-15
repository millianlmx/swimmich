import SwiftUI

/// The two closed appearance axes of the Preferences screen (settings-parity,
/// gap G22).
///
/// Both are stored by `AppSettingsStore` and projected **once** at the root:
/// the theme through `preferredColorScheme(_:)`, the accent through a single
/// `.tint(_:)`. Neither rewrites a DesignSystem token — `ImmichColors` is one
/// dynamic color per intent, and a per-preset palette would double every token
/// and every component for a setting that only needs one modifier.

/// Interface style. `colorScheme` is `nil` for `.system` — the value that hands
/// the decision back to iOS, which is what the app does today.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Accent presets. A closed list rather than a color picker: the ask is "another
/// color than the blue-violet", and one `.tint` covers every control the app
/// draws (Picker, Toggle, Stepper, NavigationLink, `.borderedProminent`).
///
/// `.immich` returns the brand color itself, so leaving the setting untouched
/// keeps exactly today's rendering.
enum AppAccent: String, CaseIterable, Identifiable {
    case immich, blue, green, orange, pink, purple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .immich: return String(localized: "Immich")
        case .blue: return String(localized: "Blue")
        case .green: return String(localized: "Green")
        case .orange: return String(localized: "Orange")
        case .pink: return String(localized: "Pink")
        case .purple: return String(localized: "Purple")
        }
    }

    var color: Color {
        switch self {
        case .immich: return Color.immichPrimary
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .pink: return .pink
        case .purple: return .purple
        }
    }
}
