import XCTest
@testable import MonaGuard

final class TransactionIntentTests: XCTestCase {
    private func make(_ tx: [String: Any]) throws -> TransactionIntent {
        try TransactionIntent(requestId: "7", origin: Fixture.origin, params: [tx], account: Fixture.account)
    }
    private var base: [String: Any] {
        ["from": Fixture.account.lowercased, "to": Fixture.token.lowercased, "value": "0x0", "data": Hex.encode(Fixture.approve(.max))]
    }

    func testValidIntent() throws {
        let i = try make(base)
        XCTAssertEqual(i.chainId, 10143)
        XCTAssertEqual(i.to, Fixture.token)
        XCTAssertEqual(i.data, Fixture.approve(.max))
    }

    func testFromMustBeConnectedAccount() {
        var tx = base; tx["from"] = Fixture.spender.lowercased
        XCTAssertThrowsError(try make(tx)) { XCTAssertEqual($0 as? TransactionIntent.ValidationError, .wrongAccount) }
    }

    func testMainnetChainRejected() {
        var tx = base; tx["chainId"] = "0x8f" // 143
        XCTAssertThrowsError(try make(tx)) { XCTAssertEqual($0 as? TransactionIntent.ValidationError, .wrongChain("0x8f")) }
    }

    func testContractCreationRejected() {
        var tx = base; tx["to"] = NSNull()
        XCTAssertThrowsError(try make(tx))
        tx.removeValue(forKey: "to")
        XCTAssertThrowsError(try make(tx))
    }

    func testUnknownFieldRejected() {
        var tx = base; tx["nonce"] = "0x1"
        XCTAssertThrowsError(try make(tx)) { XCTAssertEqual($0 as? TransactionIntent.ValidationError, .unexpectedField("nonce")) }
    }

    func testMalformedValuesRejected() {
        for (k, v) in [("value", "100"), ("value", "0x" + String(repeating: "f", count: 65)), ("data", "0x123"), ("to", "0x1234"), ("gas", "0x0"), ("type", "0x4")] as [(String, Any)] {
            var tx = base; tx[k] = v
            XCTAssertThrowsError(try make(tx), "\(k)=\(v)")
        }
        var tx = base; tx["value"] = 1
        XCTAssertThrowsError(try make(tx))
    }

    func testSiteGasLimitIsIgnored() throws {
        var tx = base; tx["gas"] = "0x1c9c37f" // ~30M: would inflate fees on Monad
        let i = try make(tx)
        XCTAssertNil(i.gasLimit)
        XCTAssertEqual(i.fingerprint, try make(base).fingerprint)
    }

    func testConflictingDataAndInputRejected() {
        var tx = base; tx["input"] = "0xdeadbeef"
        XCTAssertThrowsError(try make(tx))
    }

    func testOversizedCalldataRejected() {
        var tx = base; tx["data"] = "0x" + String(repeating: "00", count: TransactionIntent.maxCalldataBytes + 1)
        XCTAssertThrowsError(try make(tx)) { XCTAssertEqual($0 as? TransactionIntent.ValidationError, .calldataTooLarge) }
    }

    func testParamsShape() {
        XCTAssertThrowsError(try TransactionIntent(requestId: "1", origin: Fixture.origin, params: [base, base], account: Fixture.account))
        XCTAssertThrowsError(try TransactionIntent(requestId: "1", origin: Fixture.origin, params: base, account: Fixture.account))
    }

    func testFingerprintChangesWithAnyByte() throws {
        let original = try make(base)
        var mutated = Fixture.approve(.max)
        mutated[mutated.count - 1] ^= 0x01
        var tx = base; tx["data"] = Hex.encode(mutated)
        XCTAssertNotEqual(original.fingerprint, try make(tx).fingerprint)

        tx = base; tx["value"] = "0x1"
        XCTAssertNotEqual(original.fingerprint, try make(tx).fingerprint)

        let otherOrigin = try TransactionIntent(requestId: "7", origin: "https://evil.example", params: [base], account: Fixture.account)
        XCTAssertNotEqual(original.fingerprint, otherOrigin.fingerprint)
    }

    func testFingerprintStableAcrossRequestIdAndCase() throws {
        let a = try make(base)
        var tx = base; tx["to"] = Fixture.token.lowercased.uppercased().replacingOccurrences(of: "0X", with: "0x")
        let b = try TransactionIntent(requestId: "other", origin: Fixture.origin, params: [tx], account: Fixture.account)
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        XCTAssertEqual(a.fingerprint.count, 64)
    }
}
