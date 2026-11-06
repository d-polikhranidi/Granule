#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif
import ClickHouseCore

/// What the user chose in Settings > Appearance: the editor's theme and
/// size, the result's text size and density, and dark backgrounds for both
/// (as Mail's for messages). The window itself follows the system's appearance.
enum AppearanceSettings {
    static let didChange = Notification.Name("AppearanceSettingsDidChange")

    static var theme: EditorTheme {
        UserDefaults.standard.string(forKey: "EditorTheme").flatMap(EditorTheme.init(rawValue:)) ?? .standard
    }

    static var editorFontSize: CGFloat {
        let size = UserDefaults.standard.double(forKey: "EditorFontSize")
        #if os(macOS)
        return size >= 9 ? size : 13
        #else
        return size >= 9 ? size : 15
        #endif
    }

    /// The result's text size (`nil`: the system's).
    static var resultFontSize: CGFloat? {
        let size = UserDefaults.standard.double(forKey: "ResultFontSize")
        return size >= 9 ? size : nil
    }

    static var resultDensity: String { UserDefaults.standard.string(forKey: "ResultDensity") ?? "regular" }

    static var alternatingRows: Bool { UserDefaults.standard.object(forKey: "ResultAlternatingRows") as? Bool ?? true }

    static var darkContent: Bool { UserDefaults.standard.bool(forKey: "DarkContentBackground") }
}

/// The editor's colors: each theme has a light and a dark variant, chosen
/// with the system's appearance (or the dark one, with dark backgrounds on).
enum EditorTheme: String, CaseIterable {
    case standard, xcode, solarized, plain

    var title: String {
        switch self {
        case .standard: String(localized: "System")
        case .xcode: String(localized: "Xcode")
        case .solarized: String(localized: "Solarized")
        case .plain: String(localized: "Plain")
        }
    }

    /// A color for light and dark, as sRGB hex.
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> PlatformColor {
        func color(_ hex: UInt32) -> PlatformColor {
            PlatformColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        #if os(macOS)
        return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light) }
        #else
        return UIColor { $0.userInterfaceStyle == .dark ? color(dark) : color(light) }
        #endif
    }

    func color(_ kind: CHSQL.TokenKind) -> PlatformColor? {
        switch self {
        case .standard:
            switch kind {
            case .keyword: .systemPink
            case .string: .systemRed
            case .number: .systemPurple
            case .comment: .systemGray
            case .parameter, .quotedIdentifier: .systemTeal
            default: nil
            }
        case .xcode:
            switch kind {
            case .keyword: Self.dynamic(0x9B2393, 0xFC5FA3)
            case .string: Self.dynamic(0xC41A16, 0xFC6A5D)
            case .number: Self.dynamic(0x1C00CF, 0xD0BF69)
            case .comment: Self.dynamic(0x5D6C79, 0x7F8C98)
            case .parameter, .quotedIdentifier: Self.dynamic(0x0B4F79, 0x6BDFFF)
            default: nil
            }
        case .solarized:
            switch kind {
            case .keyword: Self.dynamic(0x859900, 0x859900)
            case .string: Self.dynamic(0x2AA198, 0x2AA198)
            case .number: Self.dynamic(0xD33682, 0xD33682)
            case .comment: Self.dynamic(0x93A1A1, 0x586E75)
            case .parameter, .quotedIdentifier: Self.dynamic(0x268BD2, 0x268BD2)
            default: nil
            }
        case .plain:
            kind == .comment ? .systemGray : nil
        }
    }

    /// The editor's background (`nil`: the system's text background).
    var background: PlatformColor? {
        switch self {
        case .solarized: Self.dynamic(0xFDF6E3, 0x002B36)
        default: nil
        }
    }

    var text: PlatformColor? {
        switch self {
        case .solarized: Self.dynamic(0x586E75, 0x93A1A1)
        default: nil
        }
    }

    /// Keywords in a heavier weight (the plain theme marks them so).
    var boldKeywords: Bool { self == .plain }
}

/// Colors of SQL in the editor, by token: keywords, strings, numbers,
/// comments, parameters (the theme chosen in Settings).
enum SQLHighlighting {
    static var font: PlatformFont {
        PlatformFont.monospacedSystemFont(ofSize: AppearanceSettings.editorFontSize, weight: .regular)
    }

    static var textColor: PlatformColor {
        if let text = AppearanceSettings.theme.text { return text }
        #if os(macOS)
        return .textColor
        #else
        return .label
        #endif
    }

    private static func color(_ kind: CHSQL.TokenKind) -> PlatformColor? {
        AppearanceSettings.theme.color(kind)
    }

    /// Colors the whole text (a few milliseconds for a long script), and
    /// underlines the problems found in it.
    static func apply(to storage: NSTextStorage, problems: [EditorProblem] = []) {
        let text = storage.string
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: textColor], range: whole)
        let boldKeywords = AppearanceSettings.theme.boldKeywords
        let bold = PlatformFont.monospacedSystemFont(ofSize: AppearanceSettings.editorFontSize, weight: .semibold)
        for token in CHSQL.tokens(text) {
            guard NSMaxRange(token.range) <= storage.length else { continue }
            if boldKeywords, token.kind == .keyword { storage.addAttribute(.font, value: bold, range: token.range) }
            guard let color = color(token.kind) else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: token.range)
        }
        for problem in problems {
            guard var range = problem.range, range.location < storage.length else { continue }
            range.length = max(1, min(range.length, storage.length - range.location))
            storage.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                   .underlineColor: problem.isError ? PlatformColor.systemRed : PlatformColor.systemOrange], range: range)
        }
        storage.endEditing()
    }
}
