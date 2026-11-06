import CHDecode
import Foundation
import Testing

/// Floats written in C (Ryu's shortest digits) against Swift's own shortest
/// digits: the same digits, and the text reads back as the same value.
struct CHFloatTextTests {
    /// A number's text as its significant digits and where the point is: value = 0.digits × 10^point.
    static func digits(of text: String) -> (digits: String, point: Int) {
        var text = Substring(text)
        if text.first == "-" { text = text.dropFirst() }
        let parts = text.split(whereSeparator: { $0 == "e" || $0 == "E" })
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let mantissa = parts[0]
        let whole = mantissa.prefix { $0 != "." }
        var digits = mantissa.filter { $0 != "." }
        var point = whole.count + exponent
        while digits.first == "0", digits.count > 1 { digits.removeFirst(); point -= 1 }
        while digits.last == "0", digits.count > 1 { digits.removeLast() }
        return (String(digits), point)
    }

    static func text(_ value: Double) -> String {
        var buffer = [CChar](repeating: 0, count: 32)
        let count = ch_format_float64(value, &buffer)
        return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func text(_ value: Float) -> String {
        var buffer = [CChar](repeating: 0, count: 32)
        let count = ch_format_float32(value, &buffer)
        return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    @Test func doublesHaveTheirShortestDigits() {
        var values: [Double] = [1, -1, 0.1, 0.2, 0.3, 2.5, 100, 1e20, 1e21, 1e22, 1e-6, 1e-7, 123456789012345678901234.0,
                                9007199254740992, 9007199254740993, 4503599627370497.5, .leastNonzeroMagnitude, .leastNormalMagnitude,
                                .greatestFiniteMagnitude, -.greatestFiniteMagnitude, .ulpOfOne, 1 / 3, 2 / 3, 5e-324, 1.5e300]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<1_000_000 {
            let value = Double(bitPattern: generator.next())
            if value.isFinite, value != 0 { values.append(value) }
        }
        // Values like prices and metrics: few decimals.
        for _ in 0..<200_000 { values.append(Double(Int.random(in: -10_000_000...10_000_000)) / [10, 100, 1000, 7][Int.random(in: 0...3)]) }
        var wrong: [String] = []
        for value in values where value != 0 {
            let text = Self.text(value)
            if Double(text)?.bitPattern != value.bitPattern || Self.digits(of: text) != Self.digits(of: value.description) {
                wrong.append("\(value.description) → \(text)")
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) wrong, e.g. \(wrong.prefix(5))")
        #expect([0.0, -0.0, .nan, -.nan, .infinity, -.infinity].map(Self.text) == ["0", "-0", "nan", "nan", "inf", "-inf"])
        // JavaScript's limits for exponents, as ClickHouse.
        #expect([1e20, 1e21, 1.5e-6, 1e-7, 123.456, 0.001].map(Self.text) == ["100000000000000000000", "1e21", "0.0000015", "1e-7", "123.456", "0.001"])
    }

    @Test func floatsHaveTheirShortestDigits() {
        var values: [Float] = [1, 0.1, 3.14, 16_777_216, .leastNonzeroMagnitude, .greatestFiniteMagnitude, 1e-7, 1e21]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<1_000_000 {
            let value = Float(bitPattern: UInt32(truncatingIfNeeded: generator.next()))
            if value.isFinite, value != 0 { values.append(value) }
        }
        var wrong: [String] = []
        for value in values {
            let text = Self.text(value)
            if Float(text)?.bitPattern != value.bitPattern || Self.digits(of: text) != Self.digits(of: value.description) {
                wrong.append("\(value.description) → \(text)")
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) wrong, e.g. \(wrong.prefix(5))")
    }
}
