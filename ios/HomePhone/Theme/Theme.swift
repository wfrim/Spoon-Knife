import SwiftUI

/// A home's look: a style family (Simple, Sticker, Rotary) × a color scheme,
/// stored on the home as one key like "sticker-bubblegum". Mirrors the design
/// tokens in the canvas (tools/theme.js) so screens match the mockups.
struct Theme: Equatable {
    enum Family: String, CaseIterable, Identifiable {
        case simple, sticker, rotary
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    let key: String
    let family: Family
    let schemeName: String

    // Page
    let background: Color
    let text: Color
    let muted: Color
    // Cards
    let cardBackground: Color
    let cardText: Color
    let cardMuted: Color
    let cardBorder: Color
    let cardBorderWidth: CGFloat
    let cardRadius: CGFloat
    let cardShadow: Color?  // hard offset shadow (Sticker / Rotary)
    // Primary button
    let buttonBackground: Color
    let buttonText: Color
    let buttonBorder: Color?
    let buttonRadius: CGFloat
    let buttonShadow: Color?
    // Accents
    let accent: Color
    let onAccent: Color
    let strong: Color
    let call: Color
    let onCall: Color
    let danger: Color
    let tones: [Color]
    let onTone: Color
    // Type
    let design: Font.Design
    let headingItalic: Bool
    /// Sticker things sit a little crooked.
    let tilt: Double

    var isSimple: Bool { family == .simple }
    var isSticker: Bool { family == .sticker }
    var isRotary: Bool { family == .rotary }

    func tone(_ i: Int) -> Color { tones[((i % tones.count) + tones.count) % tones.count] }

    func heading(_ size: CGFloat) -> Font {
        let font = Font.system(size: size, weight: isRotary ? .bold : .heavy, design: design)
        return headingItalic ? font.italic() : font
    }

    func body(_ size: CGFloat = 17, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: isRotary ? .default : design)
    }
}

// MARK: - Catalog

extension Theme {
    static let defaultKey = "simple-cobalt"

    /// Every key, in picker order.
    static let keys: [String] = Family.allCases.flatMap { family in schemes(for: family).map { "\(family.rawValue)-\($0.key)" } }

    struct Scheme: Identifiable {
        let key: String
        let name: String
        let swatch: (UInt32, UInt32)
        var id: String { key }
    }

    static func schemes(for family: Family) -> [Scheme] {
        switch family {
        case .simple: return simple.map { Scheme(key: $0.key, name: $0.name, swatch: ($0.accent, 0xF6F7FB)) }
        case .sticker: return sticker.map { Scheme(key: $0.key, name: $0.name, swatch: ($0.hero, $0.pink)) }
        case .rotary: return rotary.map { Scheme(key: $0.key, name: $0.name, swatch: ($0.dial, $0.wood)) }
        }
    }

    static func named(_ key: String?) -> Theme {
        let parts = (key ?? defaultKey).split(separator: "-").map(String.init)
        let family = Family(rawValue: parts.first ?? "") ?? .simple
        let scheme = parts.count > 1 ? parts[1] : ""
        switch family {
        case .simple: return simpleTheme(simple.first { $0.key == scheme } ?? simple[0])
        case .sticker: return stickerTheme(sticker.first { $0.key == scheme } ?? sticker[0])
        case .rotary: return rotaryTheme(rotary.first { $0.key == scheme } ?? rotary[0])
        }
    }

    /// Before you have a home: the energetic "Pop" house style used in onboarding.
    static let house = Theme(
        key: "house", family: .simple, schemeName: "Pop",
        background: Color(hex: 0xFFF8F1), text: Color(hex: 0x14172B), muted: Color(hex: 0x5B6075),
        cardBackground: .white, cardText: Color(hex: 0x14172B), cardMuted: Color(hex: 0x5B6075),
        cardBorder: Color(hex: 0xE4DCD2), cardBorderWidth: 1, cardRadius: 18, cardShadow: nil,
        buttonBackground: Color(hex: 0x3B5BFD), buttonText: .white, buttonBorder: nil, buttonRadius: 16, buttonShadow: nil,
        accent: Color(hex: 0x3B5BFD), onAccent: .white, strong: Color(hex: 0x3B5BFD),
        call: Color(hex: 0x0E9F6E), onCall: .white, danger: Color(hex: 0xB91C1C),
        tones: [Color(hex: 0xFFD43B), Color(hex: 0xE23C7A), Color(hex: 0x0E9F6E), Color(hex: 0x3B5BFD)], onTone: Color(hex: 0x14172B),
        design: .default, headingItalic: false, tilt: 0)

    // Palettes (same values as the canvas).
    private struct SimpleP { let key, name: String; let accent, soft: UInt32 }
    private struct StickerP { let key, name: String; let bg, hero, yellow, pink, go, soft, ink, onBg, muted, strong: UInt32 }
    private struct RotaryP { let key, name: String; let bg, dial, dialShadow, wood, ok, text, muted, onDial: UInt32 }

    private static let simple: [SimpleP] = [
        .init(key: "cobalt", name: "Cobalt", accent: 0x1D4ED8, soft: 0xE8EEFF),
        .init(key: "ember", name: "Ember", accent: 0xC2410C, soft: 0xFDEBDD),
        .init(key: "forest", name: "Forest", accent: 0x166534, soft: 0xE3F4E8),
        .init(key: "plum", name: "Plum", accent: 0x7E22CE, soft: 0xF3E8FF),
    ]
    private static let sticker: [StickerP] = [
        .init(key: "bubblegum", name: "Bubblegum", bg: 0xFFEFE3, hero: 0x8FD3FF, yellow: 0xFFC94D, pink: 0xFF8FB8, go: 0x7BE0A3, soft: 0xD8C8FF, ink: 0x2B2140, onBg: 0x2B2140, muted: 0x5A4E73, strong: 0x2B2140),
        .init(key: "pool", name: "Pool", bg: 0xE3F6F5, hero: 0xFFB4A2, yellow: 0xFFE066, pink: 0x8EC5FF, go: 0x6EE7B7, soft: 0xC4B5FD, ink: 0x12343B, onBg: 0x12343B, muted: 0x3E5D63, strong: 0x12343B),
        .init(key: "night", name: "Night", bg: 0x241A3D, hero: 0xFF8FB8, yellow: 0xFFC94D, pink: 0x8FD3FF, go: 0x7BE0A3, soft: 0xD8C8FF, ink: 0x0F0A1C, onBg: 0xFFF7EE, muted: 0xCFC3E6, strong: 0xFF8FB8),
    ]
    private static let rotary: [RotaryP] = [
        .init(key: "mustard", name: "Mustard", bg: 0xF4E7CC, dial: 0xE3A72F, dialShadow: 0xB9821C, wood: 0x4A2C1A, ok: 0x6B7A2E, text: 0x3A2213, muted: 0x6E5340, onDial: 0x3A2213),
        .init(key: "avocado", name: "Avocado", bg: 0xEEF0DD, dial: 0x8A9A3B, dialShadow: 0x66742A, wood: 0x2F3A1A, ok: 0xD98E2B, text: 0x26301A, muted: 0x5B6447, onDial: 0x1C2410),
        .init(key: "rust", name: "Rust", bg: 0xF7E4D7, dial: 0xC2562B, dialShadow: 0x8F3B1B, wood: 0x3B1F14, ok: 0x5E7B3A, text: 0x3B1F14, muted: 0x7A5443, onDial: 0xFFFFFF),
        .init(key: "bakelite", name: "Bakelite", bg: 0xEFE6D2, dial: 0x1F1C1A, dialShadow: 0x000000, wood: 0x1F1C1A, ok: 0xB3361E, text: 0x1F1C1A, muted: 0x5E574F, onDial: 0xFFFFFF),
    ]

    private static func simpleTheme(_ p: SimpleP) -> Theme {
        let ink = Color(hex: 0x14172B), muted = Color(hex: 0x5B6075), accent = Color(hex: p.accent)
        return Theme(
            key: "simple-\(p.key)", family: .simple, schemeName: p.name,
            background: Color(hex: 0xF6F7FB), text: ink, muted: muted,
            cardBackground: .white, cardText: ink, cardMuted: muted,
            cardBorder: Color(hex: 0xE4E6EC), cardBorderWidth: 1, cardRadius: 18, cardShadow: nil,
            buttonBackground: accent, buttonText: .white, buttonBorder: nil, buttonRadius: 16, buttonShadow: nil,
            accent: accent, onAccent: .white, strong: accent,
            call: Color(hex: 0x15803D), onCall: .white, danger: Color(hex: 0xB91C1C),
            tones: [accent, Color(hex: 0x0F766E), Color(hex: 0xB45309), Color(hex: 0x7C3AED)], onTone: .white,
            design: .default, headingItalic: false, tilt: 0)
    }

    private static func stickerTheme(_ p: StickerP) -> Theme {
        let ink = Color(hex: p.ink)
        return Theme(
            key: "sticker-\(p.key)", family: .sticker, schemeName: p.name,
            background: Color(hex: p.bg), text: Color(hex: p.onBg), muted: Color(hex: p.muted),
            cardBackground: .white, cardText: ink, cardMuted: Color(hex: 0x5A4E73),
            cardBorder: ink, cardBorderWidth: 2.5, cardRadius: 22, cardShadow: ink,
            buttonBackground: Color(hex: p.go), buttonText: ink, buttonBorder: ink, buttonRadius: 29, buttonShadow: ink,
            accent: Color(hex: p.hero), onAccent: ink, strong: Color(hex: p.strong),
            call: Color(hex: p.go), onCall: ink, danger: Color(hex: 0xB3261E),
            tones: [Color(hex: p.hero), Color(hex: p.yellow), Color(hex: p.pink), Color(hex: p.soft)], onTone: ink,
            design: .rounded, headingItalic: false, tilt: -3)
    }

    private static func rotaryTheme(_ p: RotaryP) -> Theme {
        let wood = Color(hex: p.wood)
        return Theme(
            key: "rotary-\(p.key)", family: .rotary, schemeName: p.name,
            background: Color(hex: p.bg), text: Color(hex: p.text), muted: Color(hex: p.muted),
            cardBackground: .white.opacity(0.55), cardText: Color(hex: p.text), cardMuted: Color(hex: p.muted),
            cardBorder: wood, cardBorderWidth: 1.5, cardRadius: 14, cardShadow: nil,
            buttonBackground: wood, buttonText: Color(hex: p.bg), buttonBorder: nil, buttonRadius: 14, buttonShadow: Color(hex: p.dialShadow),
            accent: Color(hex: p.dial), onAccent: Color(hex: p.onDial), strong: wood,
            call: Color(hex: p.ok), onCall: .white, danger: Color(hex: 0x9B2C1C),
            tones: [wood, Color(hex: p.ok), Color(hex: p.dialShadow), Color(hex: p.text)], onTone: .white,
            design: .serif, headingItalic: true, tilt: 0)
    }
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.house
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
