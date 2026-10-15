import AppKit
import CoreText

/*
 * The look of the native pages: Mahfin's own fonts (bundled — Bricolage
 * Grotesque for headings, Inter for everything else, both OFL) and the colour
 * tokens of the theme the web app reports, so a native page and the web bar
 * above it read as one surface.
 */
enum Theme {
    struct Palette {
        var void: NSColor          // --t-void, the page ground
        var void2: NSColor         // --t-void-2, raised surfaces
        var ink: NSColor           // --t-ink, primary text
        var muted: NSColor         // --t-muted, secondary text
        var accent: NSColor        // --t-accent
        var accentInk: NSColor     // --t-accent-ink, text on the accent
        var glass: NSColor         // --t-glass
        var glassStrong: NSColor   // --t-glass-strong
        var glassBorder: NSColor   // --t-glass-border
        var panel: NSColor         // --t-panel, the glass-dark fill
        var placeholderFrom: NSColor
        var placeholderTo: NSColor
        var alert: NSColor
    }

    private(set) static var palette = palettes["goldenhour"]!
    private(set) static var name = "goldenhour"

    static func use(_ theme: String) {
        guard theme != name else { return }
        name = theme
        palette = palettes[theme] ?? palettes["goldenhour"]!
    }

    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    /// Mahfin's globals.css: the themes whose shells are drawn natively (the
    /// top bar's Golden Hour and the board's IOS).
    static var palettes: [String: Palette] = [
        "goldenhour": Palette(
            void: rgb(0x08080a), void2: rgb(0x101014), ink: rgb(0xf5f5f7), muted: rgb(0x9a9aa2),
            accent: rgb(0xe8b54a), accentInk: rgb(0x2a1e08),
            glass: rgb(0xffffff, 0.06), glassStrong: rgb(0xffffff, 0.11), glassBorder: rgb(0xffffff, 0.14),
            panel: rgb(0x0e0e12, 0.72), placeholderFrom: rgb(0x1b1b22), placeholderTo: rgb(0x101014),
            alert: rgb(0xe5484d)),
        // `[data-theme="ios"]`, the board shell: warm black, bone-white accent.
        "ios": Palette(
            void: rgb(0x0a0908), void2: rgb(0x17140f), ink: rgb(0xf7f5f2), muted: rgb(0x9a938a),
            accent: rgb(0xf2ede3), accentInk: rgb(0x14110d),
            glass: rgb(0xffffff, 0.05), glassStrong: rgb(0xffffff, 0.09), glassBorder: rgb(0xffffff, 0.1),
            panel: rgb(0x12100d, 0.82), placeholderFrom: rgb(0x241f18), placeholderTo: rgb(0x17140f),
            alert: rgb(0xe5484d)),
    ]

    // MARK: Fonts

    private static var registered = false

    static func registerFonts() {
        guard !registered else { return }
        registered = true
        for name in ["Inter", "BricolageGrotesque"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    /// Inter at a weight (variable font axis), falling back to the system font.
    static func text(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        variable("Inter", size: size, weight: weight) ?? .systemFont(ofSize: size, weight: weight)
    }

    /// Bricolage Grotesque, for headings and titles. The web loads it at 400,
    /// 600 and 800 only, so its "bold" headings render at 800: matched here.
    static func display(_ size: CGFloat, _ weight: NSFont.Weight = .bold) -> NSFont {
        let w: NSFont.Weight = weight.rawValue >= NSFont.Weight.bold.rawValue ? .heavy
            : weight.rawValue >= NSFont.Weight.medium.rawValue ? .semibold : .regular
        return variable("Bricolage Grotesque", size: size, weight: w) ?? .systemFont(ofSize: size, weight: weight)
    }

    // MARK: Motion (globals.css)

    /// "expo-out", cubic-bezier(0.22, 1, 0.36, 1): every lift, reveal and slide.
    static let expoOut = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    /// "spring", cubic-bezier(0.34, 1.56, 0.64, 1): pills, play marks, nudge buttons.
    static let spring = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)
    /// Tailwind's default transition curve, cubic-bezier(0.4, 0, 0.2, 1), 150 ms.
    static let standard = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
    static let easeOut = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)

    private static var fontCache: [String: NSFont] = [:]

    private static func variable(_ family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        let key = "\(family)|\(size)|\(weight.rawValue)"
        if let f = fontCache[key] { return f }
        registerFonts()
        // CSS weight from NSFont.Weight: regular 0 → 400, bold 0.4 → 700.
        let css: CGFloat = {
            switch weight {
            case .ultraLight: return 200
            case .thin: return 100
            case .light: return 300
            case .regular: return 400
            case .medium: return 500
            case .semibold: return 600
            case .bold: return 700
            case .heavy: return 800
            case .black: return 900
            default: return 400
            }
        }()
        let wght: UInt32 = 0x7767_6874   // 'wght'
        let desc = NSFontDescriptor(fontAttributes: [
            .family: family,
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wght: css],
        ])
        guard let font = NSFont(descriptor: desc, size: size), font.familyName == family else { return nil }
        fontCache[key] = font
        return font
    }
}
