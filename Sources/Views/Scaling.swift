import SwiftUI

/// App-wide UI zoom factor, propagated through the environment so every view can
/// scale its fixed point sizes crisply (no blurry .scaleEffect). macOS has no
/// system-wide window zoom, so we thread our own factor everywhere.
private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

extension View {
    /// A system font whose point size is multiplied by the ambient UI scale.
    /// Use instead of `.font(.system(size:))` so the control scales with zoom.
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular,
                    design: Font.Design = .default) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design))
    }
}

struct ScaledFontModifier: ViewModifier {
    @Environment(\.uiScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    @ViewBuilder
    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

/// Multiplies a fixed point value by the ambient UI scale. Use for paddings,
/// frame sizes, corner radii and spacings so geometry scales together with the
/// fonts. Pure arithmetic — no `.scaleEffect`, so it costs nothing at render
/// time and keeps text crisp.
struct ScaledGeometry {
    let scale: CGFloat
    func callAsFunction(_ value: CGFloat) -> CGFloat { value * scale }
}

extension EnvironmentValues {
    /// `s(8)` → `8 * uiScale`. Read once per view with `@Environment(\.s)`.
    var s: ScaledGeometry {
        ScaledGeometry(scale: self[UIScaleKey.self])
    }
}
