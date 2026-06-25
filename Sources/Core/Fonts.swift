import SwiftUI
import AppKit

/// Fonts for the conversation text (prose + monospaced code/tools), chosen in
/// Settings. UI chrome (toolbar, list, sidebar, outline) keeps system fonts.
///
/// `family == ""` means "system default": prose falls back to `.system(...)`,
/// mono to `.system(..., design: .monospaced)`. A named family is resolved to a
/// concrete `NSFont` of that family — `Font.custom` expects a PostScript/face
/// name and silently no-ops for many family names (SF*, Menlo, Nerd Fonts), so
/// we resolve the face ourselves via NSFontManager.
enum DialogFonts {
    /// Selected prose family; "" = system. Set from AppModel / Settings.
    static var proseFamily: String = ""
    /// Selected monospaced family; "" = system monospaced.
    static var monoFamily: String = ""

    static func prose(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        font(family: proseFamily, size: size, weight: weight, monospacedFallback: false)
    }

    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        font(family: monoFamily, size: size, weight: weight, monospacedFallback: true)
    }

    private static func font(family: String, size: CGFloat,
                             weight: Font.Weight, monospacedFallback: Bool) -> Font {
        let f = family.trimmingCharacters(in: .whitespaces)
        if f.isEmpty {
            return monospacedFallback
                ? .system(size: size, weight: weight, design: .monospaced)
                : .system(size: size, weight: weight)
        }
        if let ns = nsFont(family: f, size: size, weight: weight) {
            return Font(ns)
        }
        // Family resolved to nothing → keep the sensible system default.
        return monospacedFallback
            ? .system(size: size, weight: weight, design: .monospaced)
            : .system(size: size, weight: weight)
    }

    /// Resolve a family name + weight to a concrete NSFont. Tries the member of
    /// the family closest to the requested weight, then a plain `NSFont(name:)`.
    private static func nsFont(family: String, size: CGFloat, weight: Font.Weight) -> NSFont? {
        let mgr = NSFontManager.shared
        let traits: NSFontTraitMask = []
        let appKitWeight: Int = {
            switch weight {
            case .bold, .heavy, .black: return 9
            case .semibold: return 8
            case .medium: return 6
            case .light, .thin, .ultraLight: return 3
            default: return 5
            }
        }()
        if let f = mgr.font(withFamily: family, traits: traits,
                            weight: appKitWeight, size: size) {
            return f
        }
        return NSFont(name: family, size: size)
    }

    /// A family's own font for previewing it in the picker; system body if unresolved.
    static func preview(family: String, size: CGFloat) -> Font {
        if let ns = nsFont(family: family, size: size, weight: .regular) { return Font(ns) }
        return .system(size: size)
    }

    /// Installed font families, with the leading "." (hidden system) entries
    /// dropped — for populating the Settings pickers.
    static func availableFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }
}
