import SwiftUI
import UIKit

/// Semantic design tokens from `design/tokens.json` (authority: 07-DESIGN-SYSTEM.md).
///
/// Colors are dynamic `UIColor`s, so they resolve per trait collection in sheets, alerts and
/// both appearances without threading a `ColorScheme` through views. Photos keep their own
/// colors; tokens only style chrome. Read them with `@Environment(\.tokens) private var tokens`.
struct DesignTokens {
    let background = Self.dynamic(light: 0xF4EFE6, dark: 0x141719)
    let surface = Self.dynamic(light: 0xFFFDF8, dark: 0x20262A)
    let surfaceRaised = Self.dynamic(light: 0xEAE4DA, dark: 0x2C353A)
    let textPrimary = Self.dynamic(light: 0x1A1A1A, dark: 0xF4EFE6)
    let textSecondary = Self.dynamic(light: 0x4E5960, dark: 0xC2CBD0)
    let primary = Self.dynamic(light: 0x0F4C81, dark: 0x7EC5E8)
    let onPrimary = Self.dynamic(light: 0xFFFFFF, dark: 0x102331)
    let brandRed = Self.dynamic(light: 0xB83A30, dark: 0xF18D7E)
    /// Illustration only; never body text.
    let decorativeRed = Self.dynamic(light: 0xD6453A, dark: 0xD6453A)
    let border = Self.dynamic(light: 0xCABFB0, dark: 0x53636C)
    let controlBoundary = Self.dynamic(light: 0x68737A, dark: 0x9CAFB9)
    let success = Self.dynamic(light: 0x21604D, dark: 0x9DDBC2)
    let warning = Self.dynamic(light: 0x805300, dark: 0xF3CF7B)
    let destructive = Self.dynamic(light: 0x9F3028, dark: 0xFFB4A8)

    /// Spacing scale 4, 8, 12, 16, 24, 32, 48.
    enum Spacing {
        static let xxs: CGFloat = 4, xs: CGFloat = 8, s: CGFloat = 12, m: CGFloat = 16
        static let l: CGFloat = 24, xl: CGFloat = 32, xxl: CGFloat = 48
    }
    /// Corner radii; pills use `Capsule()`.
    enum Radius {
        static let card: CGFloat = 16, control: CGFloat = 12
    }
    enum Layout {
        static let minimumHit: CGFloat = 44, reviewHit: CGFloat = 48
        static let compactMargin: CGFloat = 16, regularMargin: CGFloat = 24
        static let photoCardMin: CGFloat = 160, personCardMin: CGFloat = 136
        /// Dense Library browsing grid (mockup 02-library): about four tiles across the detail column.
        static let photoGridMin: CGFloat = 104
    }

    static let standard = DesignTokens()

    /// Compatibility for callers that still pass a scheme; colors are dynamic either way.
    init(scheme: ColorScheme? = nil) {}

    /// Legacy alias for supporting text.
    var secondary: Color { textSecondary }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

private struct DesignTokensKey: EnvironmentKey {
    static let defaultValue = DesignTokens.standard
}

extension EnvironmentValues {
    var tokens: DesignTokens {
        get { self[DesignTokensKey.self] }
        set { self[DesignTokensKey.self] = newValue }
    }
}

/// Opaque card on the paper canvas: surface fill, card radius, standard padding.
struct CardBackground: ViewModifier {
    var raised = false
    var padding: CGFloat = DesignTokens.Spacing.m
    @Environment(\.tokens) private var tokens
    func body(content: Content) -> some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(raised ? tokens.surfaceRaised : tokens.surface,
                        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
    }
}

extension View {
    func card(raised: Bool = false, padding: CGFloat = DesignTokens.Spacing.m) -> some View {
        modifier(CardBackground(raised: raised, padding: padding))
    }
}

/// Capsule action. `prominent` fills with primary; otherwise a raised neutral capsule.
struct CapsuleButtonStyle: ButtonStyle {
    var prominent = true
    var minHeight: CGFloat = DesignTokens.Layout.minimumHit
    @Environment(\.tokens) private var tokens
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, DesignTokens.Spacing.m)
            .frame(minHeight: minHeight)
            .foregroundStyle(prominent ? tokens.onPrimary : tokens.primary)
            .background(prominent ? tokens.primary : tokens.surfaceRaised, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    static var capsule: CapsuleButtonStyle { CapsuleButtonStyle() }
    static var capsuleSecondary: CapsuleButtonStyle { CapsuleButtonStyle(prominent: false) }
}

/// Explicit destructive action: destructive-token text and outline on the surface color.
/// Never filled, so it cannot be mistaken for the screen's primary action.
struct DestructiveCapsuleButtonStyle: ButtonStyle {
    var minHeight: CGFloat = DesignTokens.Layout.minimumHit
    @Environment(\.tokens) private var tokens
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, DesignTokens.Spacing.m)
            .frame(minHeight: minHeight)
            .foregroundStyle(tokens.destructive)
            .background(tokens.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(tokens.destructive, lineWidth: 1.5))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == DestructiveCapsuleButtonStyle {
    static var capsuleDestructive: DestructiveCapsuleButtonStyle { DestructiveCapsuleButtonStyle() }
}

/// Selected/unselected capsule pill used for section filters.
struct PillLabel: View {
    let title: String
    let selected: Bool
    @Environment(\.tokens) private var tokens
    var body: some View {
        Text(title).font(.subheadline.weight(.semibold))
            .padding(.horizontal, DesignTokens.Spacing.m).frame(minHeight: DesignTokens.Layout.minimumHit)
            .foregroundStyle(selected ? tokens.onPrimary : tokens.textPrimary)
            .background(selected ? tokens.primary : tokens.surfaceRaised, in: Capsule())
    }
}
