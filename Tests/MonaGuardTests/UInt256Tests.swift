import XCTest
@testable import MonaGuard

final class UInt256Tests: XCTestCase {
    func testMaxRoundTrip() {
        let max = UInt256(hex: "0x" + String(repeating: "f", count: 64))
        XCTAssertEqual(max, .max)
        XCTAssertEqual(UInt256.max.decimalString, "115792089237316195423570985008687907853269984665640564039457584007913129639935")
        XCTAssertEqual(UInt256(decimal: UInt256.max.decimalString), .max)
    }

    func testOverflowRejected() {
        XCTAssertNil(UInt256(hex: "0x1" + String(repeating: "0", count: 64)))
        XCTAssertNil(UInt256(decimal: "115792089237316195423570985008687907853269984665640564039457584007913129639936"))
        XCTAssertNil(UInt256.max.addingReportingOverflow(1))
    }

    func testLeadingZerosAndCase() {
        XCTAssertEqual(UInt256(hex: "0x" + String(repeating: "0", count: 70) + "Ff"), UInt256(255))
        XCTAssertEqual(UInt256(hex: "0x0"), .zero)
        XCTAssertNil(UInt256(hex: "0x"))
        XCTAssertNil(UInt256(hex: "ff"))
        XCTAssertNil(UInt256(hex: "0xzz"))
        XCTAssertNil(UInt256(hex: "0x-1"))
    }

    func testHexQuantity() {
        XCTAssertEqual(UInt256.zero.hexQuantity, "0x0")
        XCTAssertEqual(UInt256(10143).hexQuantity, "0x279f")
    }

    func testFormattingHasNoPrecisionLoss() {
        // 1.000000000000000001 MON: a Double would print 1.0
        let v = UInt256(decimal: "1000000000000000001")!
        XCTAssertEqual(v.formatted(decimals: 18, maxFractionDigits: 18), "1.000000000000000001")
        XCTAssertEqual(UInt256(decimal: "1500000000000000000")!.formatted(decimals: 18), "1.5")
        XCTAssertEqual(UInt256(1).formatted(decimals: 18, maxFractionDigits: 18), "0.000000000000000001")
        XCTAssertEqual(UInt256(1).formatted(decimals: 18, maxFractionDigits: 4), "<0.0001")
        XCTAssertEqual(UInt256(1_000_000).formatted(decimals: 6), "1")
        XCTAssertEqual(UInt256(42).formatted(decimals: 0), "42")
    }

    func testBigEndianBytes() {
        let v = UInt256(bigEndian: Data([0x01, 0x00]))!
        XCTAssertEqual(v, UInt256(256))
        XCTAssertEqual(v.bigEndianBytes.count, 32)
        XCTAssertNil(UInt256(bigEndian: Data(repeating: 1, count: 33)))
    }
}

final class DecimalAmountTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(UInt256(decimalAmount: "0.001", decimals: 18), UInt256(decimal: "1000000000000000"))
        XCTAssertEqual(UInt256(decimalAmount: "1", decimals: 18), UInt256(decimal: "1000000000000000000"))
        XCTAssertEqual(UInt256(decimalAmount: ".5", decimals: 1), UInt256(5))
        XCTAssertEqual(UInt256(decimalAmount: "0.000000000000000001", decimals: 18), UInt256(1))
        for bad in ["", ".", "-1", "1e3", "0.0000000000000000001", "1.2.3", "abc", "1,5", " 1 2"] {
            XCTAssertNil(UInt256(decimalAmount: bad, decimals: 18), bad)
        }
    }
}
