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
import SwiftUI

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
        return size >= 9 ? size : defaultEditorFontSize
    }

    #if os(macOS)
    static let defaultEditorFontSize: CGFloat = 13
    #else
    static let defaultEditorFontSize: CGFloat = 15
    #endif

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

/// Settings > Appearance: the Mac's Settings window pane, a sheet on the iPad and iPhone.
/// Settings › Queries: what's asked before a query runs.
struct QuerySettingsSection: View {
    @AppStorage(LargeReads.asksKey) private var asks = true
    @AppStorage(LargeReads.rowsKey) private var rows = LargeReads.defaultRows

    var body: some View {
        Section {
            Toggle(isOn: $asks) {
                Text("Ask before a query reads many rows")
                Text("By the server's estimate from its indexes (MergeTree tables), before the query runs. A query that stops at its LIMIT isn't asked about.")
            }
            Picker("More than", selection: $rows) {
                Text("100 million rows").tag(1e8)
                Text("1 billion rows").tag(1e9)
                Text("10 billion rows").tag(1e10)
                Text("100 billion rows").tag(1e11)
            }
            .disabled(!asks)
        } header: {
            Text("Before Running")
        }
    }
}

#if os(macOS)
/// The Mac's Queries pane.
struct QuerySettingsView: View {
    var body: some View {
        Form { QuerySettingsSection() }
            .formStyle(.grouped)
            .frame(width: 560)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif

struct AppearanceSettingsView: View {
    /// The Queries section above (iOS: one sheet for all of Settings).
    var includesQueries = false
    @AppStorage("EditorTheme") private var theme = EditorTheme.standard.rawValue
    @AppStorage("EditorFontSize") private var editorFontSize = Double(AppearanceSettings.defaultEditorFontSize)
    @AppStorage("ResultFontSize") private var resultFontSize = 0.0
    @AppStorage("ResultDensity") private var density = "regular"
    @AppStorage("ResultAlternatingRows") private var alternatingRows = true
    @AppStorage("DarkContentBackground") private var darkContent = false
    @Environment(\.colorScheme) private var colorScheme

    private static let sample = "SELECT country, count() AS visits -- this month\nFROM events\nWHERE event_time >= {since:DateTime} AND url LIKE '%/page/%'\nGROUP BY country ORDER BY visits DESC LIMIT 10"

    var body: some View {
        Form {
            if includesQueries { QuerySettingsSection() }
            Section {
                Toggle(isOn: $darkContent) {
                    Text("Dark background for the editor and results")
                    #if os(macOS)
                    Text("The windows themselves follow System Settings › Appearance (Light, Dark or Auto).")
                    #else
                    Text("The app itself follows Settings › Display & Brightness (Light, Dark or Automatic).")
                    #endif
                }
            }
            Section("Editor") {
                Picker("Theme", selection: $theme) {
                    ForEach(EditorTheme.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                Stepper(value: $editorFontSize, in: 10...24, step: 1) {
                    LabeledContent("Font size", value: String(localized: "\(Int(editorFontSize)) pt"))
                }
                preview
            }
            Section("Results") {
                Picker("Text size", selection: $resultFontSize) {
                    Text("System").tag(0.0)
                    ForEach([11.0, 12, 13, 14, 15, 16, 18], id: \.self) { Text(String(localized: "\(Int($0)) pt")).tag($0) }
                }
                Picker("Rows", selection: $density) {
                    Text("Compact").tag("compact")
                    Text("Regular").tag("regular")
                    Text("Spacious").tag("spacious")
                }
                .pickerStyle(.segmented)
                Toggle("Alternating row backgrounds", isOn: $alternatingRows)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        #endif
        .onChange(of: theme) { changed() }
        .onChange(of: editorFontSize) { changed() }
        .onChange(of: resultFontSize) { changed() }
        .onChange(of: density) { changed() }
        .onChange(of: alternatingRows) { changed() }
        .onChange(of: darkContent) { changed() }
    }

    /// The theme on a statement, as the editor will show it.
    private var preview: some View {
        let storage = NSTextStorage(string: Self.sample)
        SQLHighlighting.apply(to: storage)
        let background = EditorTheme(rawValue: theme)?.background
        #if os(macOS)
        let fallback = Color(nsColor: .textBackgroundColor)
        let text = AttributedString(storage)
        #else
        let fallback = Color(uiColor: .secondarySystemBackground)
        let text = (try? AttributedString(storage, including: \.uiKit)) ?? AttributedString(storage.string)
        #endif
        return Text(text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(background.map { Color($0) } ?? fallback, in: .rect(cornerRadius: 6))
            .environment(\.colorScheme, darkContent ? .dark : colorScheme)
            .id("\(theme)\(editorFontSize)\(darkContent)")
    }

    private func changed() {
        NotificationCenter.default.post(name: AppearanceSettings.didChange, object: nil)
    }
}

private extension Color {
    init(_ color: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: color)
        #else
        self.init(uiColor: color)
        #endif
    }
}
