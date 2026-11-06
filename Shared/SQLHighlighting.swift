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

/// Colors of SQL in the editor, by token: keywords, strings, numbers,
/// comments, parameters.
enum SQLHighlighting {
    static var font: PlatformFont {
        #if os(macOS)
        PlatformFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        #else
        PlatformFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        #endif
    }

    static var textColor: PlatformColor {
        #if os(macOS)
        .textColor
        #else
        .label
        #endif
    }

    private static func color(_ kind: CHSQL.TokenKind) -> PlatformColor? {
        switch kind {
        case .keyword: .systemPink
        case .string: .systemRed
        case .number: .systemPurple
        case .comment: .systemGray
        case .parameter, .quotedIdentifier: .systemTeal
        default: nil
        }
    }

    /// Colors the whole text (a few milliseconds for a long script), and
    /// underlines the problems found in it.
    static func apply(to storage: NSTextStorage, problems: [EditorProblem] = []) {
        let text = storage.string
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: textColor], range: whole)
        for token in CHSQL.tokens(text) {
            guard let color = color(token.kind), NSMaxRange(token.range) <= storage.length else { continue }
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
