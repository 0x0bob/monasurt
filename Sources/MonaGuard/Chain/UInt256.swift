import Foundation

/// Fixed-width unsigned 256-bit integer used for all wei and ABI amounts. Never converted through `Double`.
/// Limbs are little-endian (limbs[0] is the least significant 64 bits).
struct UInt256: Hashable, Comparable, Sendable, CustomStringConvertible {
    private(set) var limbs: [UInt64]

    static let zero = UInt256(limbs: [0, 0, 0, 0])
    static let max = UInt256(limbs: [.max, .max, .max, .max])

    init(limbs: [UInt64]) {
        precondition(limbs.count == 4)
        self.limbs = limbs
    }

    init(_ value: UInt64) {
        self.limbs = [value, 0, 0, 0]
    }

    /// Big-endian bytes, at most 32. Returns nil if longer.
    init?(bigEndian bytes: Data) {
        guard bytes.count <= 32 else { return nil }
        let padded = Data(repeating: 0, count: 32 - bytes.count) + bytes
        var limbs = [UInt64](repeating: 0, count: 4)
        for i in 0..<4 {
            var v: UInt64 = 0
            for b in padded[padded.startIndex + i * 8 ..< padded.startIndex + i * 8 + 8] {
                v = (v << 8) | UInt64(b)
            }
            limbs[3 - i] = v
        }
        self.limbs = limbs
    }

    /// Parses a JSON-RPC quantity or a 0x-prefixed hex string. Leading zeros are accepted.
    init?(hex: String) {
        guard hex.hasPrefix("0x") || hex.hasPrefix("0X") else { return nil }
        let digits = hex.dropFirst(2)
        guard !digits.isEmpty, digits.count <= 64 else {
            // Allow over-long strings only if the excess is leading zeros.
            let trimmed = digits.drop(while: { $0 == "0" })
            guard !digits.isEmpty, trimmed.count <= 64 else { return nil }
            self.init(hex: "0x" + (trimmed.isEmpty ? "0" : String(trimmed)))
            return
        }
        var value = UInt256.zero
        for ch in digits {
            guard let d = ch.hexDigitValue else { return nil }
            value = value.shiftedLeft4() .adding(UInt64(d))
        }
        self = value
    }

    /// Parses a non-negative base-10 integer string.
    init?(decimal: String) {
        guard !decimal.isEmpty, decimal.count <= 78 else { return nil }
        var value = UInt256.zero
        for ch in decimal {
            guard let d = ch.wholeNumberValue, ch.isASCII else { return nil }
            guard let m = value.multipliedReportingOverflow(by: 10), let a = m.addingReportingOverflow(UInt64(d)) else { return nil }
            value = a
        }
        self = value
    }

    /// Parses a human decimal amount such as "0.001" into base units with `decimals` places. Rejects
    /// signs, exponents, too many fraction digits and overflow.
    init?(decimalAmount text: String, decimals: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains(where: { $0.isNumber }) else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), decimals >= 0, decimals <= 36 else { return nil }
        let whole = parts[0].isEmpty ? "0" : String(parts[0])
        let frac = parts.count == 2 ? String(parts[1]) : ""
        guard frac.count <= decimals, !(whole == "0" && parts.count == 2 && frac.isEmpty && parts[0].isEmpty) else { return nil }
        guard let v = UInt256(decimal: whole + frac + String(repeating: "0", count: decimals - frac.count)) else { return nil }
        self = v
    }

    var isZero: Bool { limbs.allSatisfy { $0 == 0 } }

    var bigEndianBytes: Data {
        var out = Data(capacity: 32)
        for i in (0..<4).reversed() {
            withUnsafeBytes(of: limbs[i].bigEndian) { out.append(contentsOf: $0) }
        }
        return out
    }

    /// Minimal JSON-RPC quantity encoding, e.g. 0x0, 0x2386f26fc10000.
    var hexQuantity: String {
        if isZero { return "0x0" }
        let hex = bigEndianBytes.map { String(format: "%02x", $0) }.joined()
        let trimmed = hex.drop(while: { $0 == "0" })
        return "0x" + trimmed
    }

    var description: String { decimalString }

    var decimalString: String {
        if isZero { return "0" }
        var digits: [Character] = []
        var current = self
        while !current.isZero {
            let (q, r) = current.dividedBy(10)
            digits.append(Character(String(r)))
            current = q
        }
        return String(digits.reversed())
    }

    /// Formats with a fixed number of decimals, trimming trailing zeros, e.g. 1500000000000000000 (18) -> "1.5".
    func formatted(decimals: Int, maxFractionDigits: Int = 6) -> String {
        let s = decimalString
        guard decimals > 0 else { return s }
        let padded = String(repeating: "0", count: Swift.max(0, decimals + 1 - s.count)) + s
        let intPart = padded.prefix(padded.count - decimals)
        var frac = String(padded.suffix(decimals))
        if frac.count > maxFractionDigits {
            let truncated = String(frac.prefix(maxFractionDigits))
            let lost = frac.dropFirst(maxFractionDigits).contains { $0 != "0" }
            frac = truncated
            while frac.hasSuffix("0") { frac.removeLast() }
            if frac.isEmpty && lost { return "<" + "0." + String(repeating: "0", count: maxFractionDigits - 1) + "1" }
            return frac.isEmpty ? String(intPart) : "\(intPart).\(frac)" + (lost ? "…" : "")
        }
        while frac.hasSuffix("0") { frac.removeLast() }
        return frac.isEmpty ? String(intPart) : "\(intPart).\(frac)"
    }

    static func < (lhs: UInt256, rhs: UInt256) -> Bool {
        for i in (0..<4).reversed() where lhs.limbs[i] != rhs.limbs[i] {
            return lhs.limbs[i] < rhs.limbs[i]
        }
        return false
    }

    func addingReportingOverflow(_ other: UInt256) -> UInt256? {
        var out = [UInt64](repeating: 0, count: 4)
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (s1, o1) = limbs[i].addingReportingOverflow(other.limbs[i])
            let (s2, o2) = s1.addingReportingOverflow(carry)
            out[i] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return carry == 0 ? UInt256(limbs: out) : nil
    }

    func addingReportingOverflow(_ small: UInt64) -> UInt256? {
        addingReportingOverflow(UInt256(small))
    }

    func multipliedReportingOverflow(by small: UInt64) -> UInt256? {
        var out = [UInt64](repeating: 0, count: 4)
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (hi, lo) = limbs[i].multipliedFullWidth(by: small)
            let (sum, o) = lo.addingReportingOverflow(carry)
            out[i] = sum
            carry = hi &+ (o ? 1 : 0)
        }
        return carry == 0 ? UInt256(limbs: out) : nil
    }

    /// Divides by a small divisor, returning quotient and remainder.
    func dividedBy(_ divisor: UInt64) -> (UInt256, UInt64) {
        precondition(divisor != 0)
        var out = [UInt64](repeating: 0, count: 4)
        var remainder: UInt64 = 0
        for i in (0..<4).reversed() {
            let (q, r) = divisor.dividingFullWidth((high: remainder, low: limbs[i]))
            out[i] = q
            remainder = r
        }
        return (UInt256(limbs: out), remainder)
    }

    fileprivate func shiftedLeft4() -> UInt256 {
        var out = [UInt64](repeating: 0, count: 4)
        for i in 0..<4 {
            out[i] = limbs[i] << 4
            if i > 0 { out[i] |= limbs[i - 1] >> 60 }
        }
        return UInt256(limbs: out)
    }

    fileprivate func adding(_ small: UInt64) -> UInt256 {
        addingReportingOverflow(small) ?? self
    }

    /// 10^exponent, or nil if it overflows.
    static func pow10(_ exponent: Int) -> UInt256? {
        var v = UInt256(1)
        for _ in 0..<exponent {
            guard let n = v.multipliedReportingOverflow(by: 10) else { return nil }
            v = n
        }
        return v
    }
}
