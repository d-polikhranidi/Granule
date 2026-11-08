import Foundation

/// An array, tuple or map as ClickHouse writes it (`[('a','b'),('c','d')]`), laid out to be
/// read: what fits in `width` characters on one line, the rest an item a line, indented.
/// ClickHouse's syntax with spaces and line breaks added; given the type, a named tuple's
/// fields are labeled (`(id: 1, name: 'a')`, as ClickHouse doesn't write them), which a
/// copy of the value shouldn't keep.
public enum CHValueLayout {
    /// Whether values of the type are laid out (arrays, tuples, maps; inside Nullable or LowCardinality).
    public static func laysOut(_ type: CHType) -> Bool {
        switch type.base {
        case .array, .tuple, .map: true
        default: false
        }
    }

    /// The value laid out, or `nil` when it isn't one bracketed value (or is empty).
    public static func laidOut(_ text: String, type: CHType? = nil, width: Int = 60) -> String? {
        var tokens = Tokens(Array(text.utf8))
        guard var node = tokens.node(), case .group = node, tokens.isAtEnd else { return nil }
        if let type { node = labeled(node, type) }
        var out = ""
        write(node, indent: 0, width: width, to: &out)
        return out
    }

    /// The value with its named tuples' fields labeled, by the type, all the way down.
    static func labeled(_ node: Node, _ type: CHType) -> Node {
        guard case .group(let open, let close, let items) = node else { return node }
        switch type.base {
        case .array(let element) where open == UInt8(ascii: "["):
            return .group(open: open, close: close, items: items.map { $0.map { labeled($0, element) } })
        case .tuple(let elements) where open == UInt8(ascii: "(") && elements.count == items.count:
            return .group(open: open, close: close, items: zip(items, elements).map { item, element in
                let parts = item.map { labeled($0, element.type) }
                return element.name.map { [.atom(Substring($0)), .atom(":")] + parts } ?? parts
            })
        case .map(let key, let value) where open == UInt8(ascii: "{"):
            return .group(open: open, close: close, items: items.map { item in
                guard item.count == 3 else { return item }
                return [labeled(item[0], key), item[1], labeled(item[2], value)]
            })
        default:
            return node
        }
    }

    indirect enum Node {
        case atom(Substring)
        /// An item's parts: a map entry is the key, ":" and the value.
        case group(open: UInt8, close: UInt8, items: [[Node]])
    }

    /// The node on one line: ", " between items, ": " in a map's entries.
    static func flat(_ node: Node) -> String {
        switch node {
        case .atom(let text): String(text)
        case .group(let open, let close, let items):
            String(UnicodeScalar(open)) + items.map(flat(item:)).joined(separator: ", ") + String(UnicodeScalar(close))
        }
    }

    private static func flat(item: [Node]) -> String {
        item.map { part in
            if case .atom(let text) = part, text == ":" { return ": " }
            return flat(part)
        }.joined()
    }

    private static func write(_ node: Node, indent: Int, width: Int, to out: inout String) {
        let line = flat(node)
        guard case .group(let open, let close, let items) = node, line.count + indent > width, !items.isEmpty else {
            out += line
            return
        }
        let inner = String(repeating: " ", count: indent + 2)
        out += String(UnicodeScalar(open)) + "\n"
        for (index, item) in items.enumerated() {
            out += inner
            for part in item {
                if case .atom(let text) = part, text == ":" {
                    out += ": "
                } else {
                    write(part, indent: indent + 2, width: width, to: &out)
                }
            }
            out += index < items.count - 1 ? ",\n" : "\n"
        }
        out += String(repeating: " ", count: indent) + String(UnicodeScalar(close))
    }

    /// ClickHouse's text: strings quoted with ' (or "), backslash escapes; brackets, commas
    /// and colons between; anything else an atom.
    struct Tokens {
        let bytes: [UInt8]
        var at = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool {
            var index = at
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x0A || bytes[index] == 0x09 || bytes[index] == 0x0D { index += 1 }
            return index == bytes.count
        }

        private mutating func skipSpaces() {
            while at < bytes.count, bytes[at] == 0x20 || bytes[at] == 0x0A || bytes[at] == 0x09 || bytes[at] == 0x0D { at += 1 }
        }

        private static func closing(_ open: UInt8) -> UInt8? {
            switch open {
            case UInt8(ascii: "["): UInt8(ascii: "]")
            case UInt8(ascii: "("): UInt8(ascii: ")")
            case UInt8(ascii: "{"): UInt8(ascii: "}")
            default: nil
            }
        }

        mutating func node() -> Node? {
            skipSpaces()
            guard at < bytes.count else { return nil }
            let byte = bytes[at]
            if let close = Self.closing(byte) {
                at += 1
                var items: [[Node]] = []
                skipSpaces()
                if at < bytes.count, bytes[at] == close {
                    at += 1
                    return .group(open: byte, close: close, items: [])
                }
                while true {
                    var item: [Node] = []
                    guard let first = node() else { return nil }
                    item.append(first)
                    skipSpaces()
                    if at < bytes.count, bytes[at] == UInt8(ascii: ":") {
                        at += 1
                        guard let value = node() else { return nil }
                        item += [.atom(":"), value]
                        skipSpaces()
                    }
                    items.append(item)
                    guard at < bytes.count else { return nil }
                    if bytes[at] == UInt8(ascii: ",") {
                        at += 1
                        continue
                    }
                    guard bytes[at] == close else { return nil }
                    at += 1
                    return .group(open: byte, close: close, items: items)
                }
            }
            return atom()
        }

        private mutating func atom() -> Node? {
            let start = at
            if bytes[at] == UInt8(ascii: "'") || bytes[at] == UInt8(ascii: "\"") {
                let quote = bytes[at]
                at += 1
                while at < bytes.count, bytes[at] != quote {
                    at += bytes[at] == UInt8(ascii: "\\") ? 2 : 1
                }
                guard at < bytes.count else { return nil }
                at += 1
            } else {
                let stops: Set<UInt8> = [UInt8(ascii: ","), UInt8(ascii: ":"), UInt8(ascii: "]"), UInt8(ascii: ")"), UInt8(ascii: "}"),
                                         UInt8(ascii: "["), UInt8(ascii: "("), UInt8(ascii: "{")]
                while at < bytes.count, !stops.contains(bytes[at]) { at += 1 }
                // (A time's colons: 2026-11-07 12:30:00 is one atom, not a map's key and value.)
                while at < bytes.count, bytes[at] == UInt8(ascii: ":"), at + 1 < bytes.count,
                      (0x30...0x39).contains(bytes[at + 1]), at > start, (0x30...0x39).contains(bytes[at - 1]) {
                    at += 1
                    while at < bytes.count, !stops.contains(bytes[at]) { at += 1 }
                }
            }
            guard at > start else { return nil }
            let text = String(decoding: bytes[start..<at], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : .atom(Substring(text))
        }
    }
}
