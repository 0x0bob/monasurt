import XCTest
@testable import MonaGuard

/// The red interruption, the trusted training-demo warning and the revoke calldata.
final class SecurityInterruptionTests: XCTestCase {
    let wmon = KnownToken.testnet.first { $0.symbol == "WMON" }!.address
    let dead = Address("0x000000000000000000000000000000000000dEaD")!

    private func intent(origin: String, data: Data, to: Address? = nil) -> TransactionIntent {
        TransactionIntent(requestId: "1", origin: origin, chainId: 10143, from: Fixture.account, to: to ?? wmon, value: .zero, data: data, gasLimit: nil)
    }
    /// Deterministic assessment with no network (what the interruption is built from before enrichment arrives).
    private func local(_ i: TransactionIntent) -> RiskAssessment { DeterministicRiskEngine.assess(i) }

    func testNebulaClaimProducesRedInterruptionFromDecodedCalldata() {
        let i = intent(origin: DemoOrigins.nebulaOrigin, data: Fixture.approve(.max, spender: dead))
        let a = local(i)
        XCTAssertEqual(a.level, .high, "unlimited approval is HIGH from calldata alone, without RPC or AI")
        let s = SecurityInterruption.make(intent: i, assessment: a)!
        XCTAssertEqual(s.headline, "STOP. THIS IS NOT A REWARD CLAIM.")
        XCTAssertEqual(s.promised, "Claim 5,000 NEB (fictional reward)")
        XCTAssertEqual(s.actual, "Unlimited WMON approval")
        XCTAssertEqual(s.tokenContract, wmon.lowercased)
        XCTAssertEqual(s.spender, dead.lowercased)
        XCTAssertTrue(s.explanation.contains("unlimited permission to spend your WMON tokens"))
        XCTAssertTrue(s.persistence!.contains("until revoked"))
        // Never overclaims: one token, nothing drained.
        for bad in ["drained", "all your assets", "all assets", "stolen"] { XCTAssertFalse((s.explanation + s.persistence!).lowercased().contains(bad)) }
    }

    func testOrdinarySiteGetsNoInventedPromise() {
        let i = intent(origin: "https://app.puddleswap.org", data: Fixture.approve(.max, spender: dead))
        let s = SecurityInterruption.make(intent: i, assessment: local(i))!
        XCTAssertNil(s.promised)
        XCTAssertEqual(s.headline, "STOP. CHECK THIS PERMISSION.")
        XCTAssertFalse(s.explanation.contains("promised"))
    }

    func testNoInterruptionForBoundedOrRevoke() {
        let bounded = intent(origin: DemoOrigins.nebulaOrigin, data: Fixture.approve(UInt256(5), spender: dead))
        XCTAssertNil(SecurityInterruption.make(intent: bounded, assessment: local(bounded)))
        let revoke = intent(origin: DemoOrigins.nebulaOrigin, data: AllowanceCalls.revokeCalldata(spender: dead))
        XCTAssertNil(SecurityInterruption.make(intent: revoke, assessment: local(revoke)))
    }

    func testTrainingDemoWarningComesFromNativeMetadataOnly() {
        XCTAssertEqual(TrainingDemo.info(for: DemoOrigins.nebulaOrigin)?.label, "SECURITY DEMO: DECEPTIVE DAPP")
        XCTAssertNil(TrainingDemo.info(for: DemoOrigins.demoOrigin))
        XCTAssertNil(TrainingDemo.info(for: "https://nebuladrop.demo"), "a web page cannot claim the training label")
        let e = SiteEvidence(origin: DemoOrigins.nebulaOrigin, loading: false, isHTTPS: false, isBundledDemo: true, hasOnlySecureContent: true,
                             urlFindings: [], reputation: .notConfigured, walletEnabled: true, isTrainingDemo: true)
        let v = SiteVerdict.derive(e)
        XCTAssertEqual(v.status, .deceptiveDemo)
        XCTAssertEqual(SecurityIndicator.derive(site: v.status, alert: nil).tone, .red)
        // The flag alone cannot mark an arbitrary origin.
        var other = e; other.origin = "https://example.com"
        XCTAssertNotEqual(SiteVerdict.derive(other).status, .deceptiveDemo)
    }

    func testNoTransactionAlertBeforeAnyRequest() {
        let book = TransactionAlertBook()
        XCTAssertNil(book.current(tabID: UUID(), origin: DemoOrigins.nebulaOrigin))
        // The pre-connect warning is a site status, not a fabricated transaction finding.
        XCTAssertEqual(SecurityIndicator.derive(site: .deceptiveDemo, alert: nil).title, "Security demo: deceptive dApp")
    }

    func testRejectedAlertDoesNotHideRedDemoWarningAndIsNotGreen() {
        let i = intent(origin: DemoOrigins.nebulaOrigin, data: Fixture.approve(.max, spender: dead))
        var book = TransactionAlertBook()
        let tab = UUID()
        book.record(TransactionAlert.make(tabID: tab, intent: i, assessment: local(i))!)
        book.resolve(tabID: tab, fingerprint: i.fingerprint, as: .rejected)
        let cur = book.current(tabID: tab, origin: DemoOrigins.nebulaOrigin)
        XCTAssertEqual(SecurityIndicator.derive(site: .deceptiveDemo, alert: cur).tone, .red)
        XCTAssertEqual(SecurityIndicator.derive(site: .noKnownThreats, alert: cur).tone, .amber)
        XCTAssertEqual(SecurityIndicator.derive(site: .noKnownThreats, alert: cur).title, "Risky request rejected")
    }

    func testRevokeCalldataTargetsSameSpenderWithZero() {
        let data = AllowanceCalls.revokeCalldata(spender: dead)
        XCTAssertEqual(Hex.encode(data), "0x095ea7b3" + String(repeating: "0", count: 24) + "000000000000000000000000000000000000dead" + String(repeating: "0", count: 64))
        XCTAssertEqual(CalldataDecoder.decode(data), .erc20Approve(spender: dead, amount: .zero))
        // With the on-chain context the app always fetches, a revoke is not flagged as risky.
        let a = DeterministicRiskEngine.assess(intent(origin: SecurityCoordinator_nativeOrigin, data: data), context: Fixture.liveContext)
        XCTAssertLessThan(a.level, .caution)
        XCTAssertNil(SecurityInterruption.make(intent: intent(origin: SecurityCoordinator_nativeOrigin, data: data), assessment: a))
    }

    func testAllowanceCalldata() {
        let data = AllowanceCalls.allowanceCalldata(owner: Fixture.account, spender: dead)
        XCTAssertEqual(Hex.encode(data).prefix(10), "0xdd62ed3e")
        XCTAssertEqual(data.count, 4 + 64)
        XCTAssertTrue(AllowanceCalls.knownSpenders.contains(dead))
    }
}

/// The app's own wallet screens use this native origin (the coordinator is in the private app); mirrored here for the tests.
private let SecurityCoordinator_nativeOrigin = "shield://wallet"
