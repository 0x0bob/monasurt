import XCTest
@testable import MonaGuard

final class CalldataDecoderTests: XCTestCase {
    func testApproveMax() {
        let decoded = CalldataDecoder.decode(Fixture.approve(.max))
        XCTAssertEqual(decoded, .erc20Approve(spender: Fixture.spender, amount: .max))
    }

    func testApproveFromLiteralHex() {
        // approve(0x3333…, 1000) encoded by hand, independent of the encoder.
        let hex = "0x095ea7b3" + "000000000000000000000000" + "3333333333333333333333333333333333333333"
            + String(repeating: "0", count: 61) + "3e8"
        XCTAssertEqual(CalldataDecoder.decode(Hex.decode(hex)!), .erc20Approve(spender: Fixture.spender, amount: UInt256(1000)))
    }

    func testTransferAndTransferFrom() {
        let t = Fixture.calldata(Selector.transfer, [CalldataDecoder.word(Fixture.spender), CalldataDecoder.word(UInt256(5))])
        XCTAssertEqual(CalldataDecoder.decode(t), .erc20Transfer(recipient: Fixture.spender, amount: UInt256(5)))
        let tf = Fixture.calldata(Selector.transferFrom, [CalldataDecoder.word(Fixture.account), CalldataDecoder.word(Fixture.spender), CalldataDecoder.word(UInt256(7))])
        XCTAssertEqual(CalldataDecoder.decode(tf), .erc20TransferFrom(owner: Fixture.account, recipient: Fixture.spender, amount: UInt256(7)))
    }

    func testSetApprovalForAll() {
        let on = Fixture.calldata(Selector.setApprovalForAll, [CalldataDecoder.word(Fixture.spender), CalldataDecoder.word(UInt256(1))])
        let off = Fixture.calldata(Selector.setApprovalForAll, [CalldataDecoder.word(Fixture.spender), CalldataDecoder.word(UInt256.zero)])
        XCTAssertEqual(CalldataDecoder.decode(on), .setApprovalForAll(operator: Fixture.spender, approved: true))
        XCTAssertEqual(CalldataDecoder.decode(off), .setApprovalForAll(operator: Fixture.spender, approved: false))
    }

    func testNonCanonicalBoolIsMalformed() {
        let two = Fixture.calldata(Selector.setApprovalForAll, [CalldataDecoder.word(Fixture.spender), CalldataDecoder.word(UInt256(2))])
        guard case .malformed = CalldataDecoder.decode(two) else { return XCTFail("bool 2 must be malformed") }
    }

    func testDirtyAddressHighBitsAreMalformed() {
        var data = Fixture.approve(UInt256(1))
        data[4] = 0xff // first byte of the address word's zero padding
        guard case .malformed = CalldataDecoder.decode(data) else { return XCTFail("dirty address must be malformed") }
    }

    func testShortAndTrailingCalldataAreMalformed() {
        guard case .malformed = CalldataDecoder.decode(Data([0x09, 0x5e, 0xa7])) else { return XCTFail("3 bytes") }
        let short = Fixture.approve(.max).dropLast(1)
        guard case .malformed = CalldataDecoder.decode(Data(short)) else { return XCTFail("short args") }
        let long = Fixture.approve(.max) + Data([0])
        guard case .malformed = CalldataDecoder.decode(long) else { return XCTFail("trailing bytes") }
        guard case .malformed = CalldataDecoder.decode(Hex.decode(Selector.approve)!) else { return XCTFail("selector only") }
    }

    func testUnknownSelector() {
        XCTAssertEqual(CalldataDecoder.decode(Hex.decode("0xdeadbeef00")!), .unknown(selector: "0xdeadbeef"))
    }

    func testEmpty() {
        XCTAssertEqual(CalldataDecoder.decode(Data()), .none)
    }

    func testStringReturnDecoding() {
        var d = CalldataDecoder.word(UInt256(32)) + CalldataDecoder.word(UInt256(4))
        d += Data("DEMO".utf8) + Data(repeating: 0, count: 28)
        XCTAssertEqual(CalldataDecoder.decodeStringReturn(d), "DEMO")
        XCTAssertNil(CalldataDecoder.decodeStringReturn(Data(repeating: 0, count: 10)))
        let huge = CalldataDecoder.word(UInt256(32)) + CalldataDecoder.word(UInt256.max)
        XCTAssertNil(CalldataDecoder.decodeStringReturn(huge))
    }

    func testHexDecodeRejectsOddAndInvalid() {
        XCTAssertNil(Hex.decode("0x123"))
        XCTAssertNil(Hex.decode("0xgg"))
        XCTAssertNil(Hex.decode("1234"))
        XCTAssertEqual(Hex.decode("0x"), Data())
    }
}

final class SwapDecoderTests: XCTestCase {
    let a = Fixture.token, b = Address("0x4444444444444444444444444444444444444444")!

    private func swapETH(to: Address, path: [Address], offset: UInt64 = 0x80, minOut: UInt256 = UInt256(5)) -> Data {
        var words: [Data] = [CalldataDecoder.word(minOut), CalldataDecoder.word(UInt256(offset)), CalldataDecoder.word(to), CalldataDecoder.word(UInt256(9_999_999_999)),
                             CalldataDecoder.word(UInt256(UInt64(path.count)))]
        words += path.map { CalldataDecoder.word($0) }
        return Fixture.calldata("0x7ff36ab5", words)
    }

    func testSwapExactETHForTokensToSelfIsCaution() {
        let data = swapETH(to: Fixture.account, path: [MonadNetwork.wmon, a])
        guard case .v2Swap(_, nil, let minOut, let path, let to, _) = CalldataDecoder.decode(data) else { return XCTFail() }
        XCTAssertEqual(minOut, UInt256(5)); XCTAssertEqual(path, [MonadNetwork.wmon, a]); XCTAssertEqual(to, Fixture.account)
        let r = DeterministicRiskEngine.assess(Fixture.intent(value: UInt256(1), data: data), context: Fixture.liveContext)
        XCTAssertEqual(r.level, .caution)
        XCTAssertFalse(r.findings.contains { $0.code == .nativeValueWithCall })
    }

    func testSwapToOtherRecipientIsHigh() {
        let r = DeterministicRiskEngine.assess(Fixture.intent(data: swapETH(to: b, path: [MonadNetwork.wmon, a])), context: Fixture.liveContext)
        XCTAssertEqual(r.level, .high)
    }

    func testSwapTokensForTokens() {
        let words: [Data] = [CalldataDecoder.word(UInt256(100)), CalldataDecoder.word(UInt256.zero), CalldataDecoder.word(UInt256(0xa0)),
                             CalldataDecoder.word(Fixture.account), CalldataDecoder.word(UInt256(1)), CalldataDecoder.word(UInt256(2)),
                             CalldataDecoder.word(a), CalldataDecoder.word(b)]
        let data = Fixture.calldata("0x38ed1739", words)
        guard case .v2Swap(_, let amountIn, _, _, _, _) = CalldataDecoder.decode(data) else { return XCTFail() }
        XCTAssertEqual(amountIn, UInt256(100))
        let r = DeterministicRiskEngine.assess(Fixture.intent(data: data), context: Fixture.liveContext)
        XCTAssertTrue(r.findings.contains { $0.title.contains("No minimum output") })
    }

    func testNonCanonicalSwapsAreMalformed() {
        let cases: [Data] = [
            swapETH(to: Fixture.account, path: [a, b], offset: 0x60),                  // wrong offset
            swapETH(to: Fixture.account, path: [a]),                                   // 1 hop
            swapETH(to: Fixture.account, path: [a, b, a, b, a, b]),                    // 6 hops
            swapETH(to: Fixture.account, path: [a, b]) + Data(repeating: 0, count: 32), // trailing word
            Data(swapETH(to: Fixture.account, path: [a, b]).dropLast(32)),             // truncated
        ]
        for c in cases { guard case .malformed = CalldataDecoder.decode(c) else { return XCTFail("\(c.count)") } }
    }

    func testWrapUnwrapOnlyInformationalAtCanonicalWMON() {
        let deposit = Hex.decode(Selector.deposit)!
        XCTAssertEqual(DeterministicRiskEngine.assess(Fixture.intent(to: MonadNetwork.wmon, value: UInt256(1), data: deposit), context: Fixture.liveContext).level, .informational)
        XCTAssertEqual(DeterministicRiskEngine.assess(Fixture.intent(to: a, value: UInt256(1), data: deposit), context: Fixture.liveContext).level, .unknown)
        let withdraw = Fixture.calldata(Selector.withdraw, [CalldataDecoder.word(UInt256(7))])
        XCTAssertEqual(CalldataDecoder.decode(withdraw), .unwrapNative(amount: UInt256(7)))
        guard case .malformed = CalldataDecoder.decode(deposit + Data([1])) else { return XCTFail() }
    }
}
