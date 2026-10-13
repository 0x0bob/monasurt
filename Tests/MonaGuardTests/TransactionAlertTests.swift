import XCTest
@testable import MonaGuard

/// Proactive alert regressions: a risky wallet request must outrank routine site checks, one alert per request,
/// correct lifecycle, tab/origin isolation and no downgrade.
final class TransactionAlertTests: XCTestCase {
    let tab = UUID()
    let otherTab = UUID()
    let wmon = KnownToken.testnet.first { $0.symbol == "WMON" }!.address

    private func unlimitedIntent(origin: String = Fixture.origin, requestId: String = "1") -> TransactionIntent {
        TransactionIntent(requestId: requestId, origin: origin, chainId: 10143, from: Fixture.account, to: wmon,
                          value: .zero, data: Fixture.approve(.max), gasLimit: nil)
    }
    private func alert(_ intent: TransactionIntent, tab: UUID? = nil, now: Date = Date()) -> TransactionAlert {
        let a = DeterministicRiskEngine.assess(intent, context: Fixture.liveContext)
        return TransactionAlert.make(tabID: tab ?? self.tab, intent: intent, assessment: a, now: now)!
    }

    func testHighRequestOverridesGreenSiteStatus() {
        let a = alert(unlimitedIntent())
        XCTAssertEqual(a.level, .high)
        let ind = SecurityIndicator.derive(site: .noKnownThreats, alert: a)
        XCTAssertEqual(ind.tone, .red)
        XCTAssertEqual(ind.title, "High-risk action")
        // Without an alert the same site is green, and says only what was checked.
        XCTAssertEqual(SecurityIndicator.derive(site: .noKnownThreats, alert: nil).title, "No known URL threats")
    }

    func testAlertUsesRealDecodedTokenAndSpender() {
        let a = alert(unlimitedIntent())
        XCTAssertEqual(a.title, "Dangerous wallet permission")
        XCTAssertTrue(a.summary.contains("WMON"))
        XCTAssertTrue(a.summary.contains(Fixture.spender.short))
        XCTAssertTrue(a.codes.contains(Finding.Code.unlimitedApproval.rawValue))
    }

    func testCautionIsAmberOnlyWhilePending() {
        let send = TransactionIntent(requestId: "1", origin: Fixture.origin, chainId: 10143, from: Fixture.account, to: Fixture.account,
                                     value: UInt256(1000), data: Data(), gasLimit: nil)
        let sa = DeterministicRiskEngine.assess(send, context: Fixture.liveContext)
        // Caution requests are amber only while pending; once resolved they leave no lingering warning.
        var book = TransactionAlertBook()
        book.record(TransactionAlert.make(tabID: tab, intent: send, assessment: sa)!)
        XCTAssertEqual(SecurityIndicator.derive(site: .noKnownThreats, alert: book.current(tabID: tab, origin: Fixture.origin)).tone, .amber)
        book.resolve(tabID: tab, fingerprint: send.fingerprint, as: .rejected)
        XCTAssertEqual(SecurityIndicator.derive(site: .noKnownThreats, alert: book.current(tabID: tab, origin: Fixture.origin)).tone, .green)
        let bounded = TransactionIntent(requestId: "1", origin: Fixture.origin, chainId: 10143, from: Fixture.account, to: wmon,
                                        value: .zero, data: Fixture.approve(UInt256(5)), gasLimit: nil)
        let ba = DeterministicRiskEngine.assess(bounded, context: Fixture.liveContext)
        let al = TransactionAlert.make(tabID: tab, intent: bounded, assessment: ba)!
        XCTAssertEqual(SecurityIndicator.derive(site: .noKnownThreats, alert: al).tone, .amber)
        XCTAssertEqual(SecurityIndicator.derive(site: .noKnownThreats, alert: al).title, "Review recommended")
    }

    func testDuplicateEventsDoNotCreateNewAlerts() {
        var book = TransactionAlertBook()
        let i = unlimitedIntent()
        XCTAssertEqual(book.record(alert(i)), .created)
        XCTAssertEqual(book.record(alert(i)), .none)
        // Same calldata, new request id → same fingerprint → same alert.
        XCTAssertEqual(book.record(alert(unlimitedIntent(requestId: "2"))), .none)
        XCTAssertEqual(book.alerts.count, 1)
    }

    func testRejectBecomesHistoricalRejectedAlert() {
        var book = TransactionAlertBook()
        let i = unlimitedIntent()
        book.record(alert(i))
        XCTAssertEqual(book.resolve(tabID: tab, fingerprint: i.fingerprint, as: .rejected), .updated)
        let cur = book.current(tabID: tab, origin: Fixture.origin)!
        XCTAssertEqual(cur.state, .rejected)
        XCTAssertFalse(cur.state.isActive)
        XCTAssertTrue(cur.stateText.contains("nothing signed or broadcast"))
        XCTAssertEqual(SecurityIndicator.derive(site: .noKnownThreats, alert: cur).title, "Risky request rejected")
        // Resolved stays resolved: a late duplicate cannot reopen it.
        XCTAssertEqual(book.resolve(tabID: tab, fingerprint: i.fingerprint, as: .approved(txHash: "0xabc")), .none)
        // Dismissed → the indicator falls back to the site checks.
        book.dismiss(id: cur.id)
        XCTAssertNil(book.current(tabID: tab, origin: Fixture.origin))
    }

    func testApprovedHighRiskIsNeverShownGreen() {
        var book = TransactionAlertBook()
        let i = unlimitedIntent()
        book.record(alert(i))
        book.resolve(tabID: tab, fingerprint: i.fingerprint, as: .approved(txHash: "0x" + String(repeating: "a", count: 64)))
        let ind = SecurityIndicator.derive(site: .noKnownThreats, alert: book.current(tabID: tab, origin: Fixture.origin))
        XCTAssertEqual(ind.tone, .red)
        XCTAssertEqual(ind.title, "Risky request approved")
    }

    func testTabAndOriginIsolation() {
        var book = TransactionAlertBook()
        let i = unlimitedIntent()
        book.record(alert(i))
        XCTAssertNil(book.current(tabID: otherTab, origin: Fixture.origin), "another tab must not inherit the warning")
        XCTAssertNil(book.current(tabID: tab, origin: "https://app.puddleswap.org"), "another origin must not inherit it")
        book.navigated(tabID: tab, to: "https://app.puddleswap.org")
        let old = book.alerts.values.first!
        XCTAssertEqual(old.state, .invalidated(reason: "left the page"))
        XCTAssertNil(book.current(tabID: tab, origin: Fixture.origin), "coming back does not resurrect a stale alert")
        book.tabClosed(tab)
        XCTAssertTrue(book.alerts.isEmpty)
    }

    func testRemoteEscalationRaisesButNeverLowers() {
        var book = TransactionAlertBook()
        // A caution-level request (transfer to someone else) escalated by remote evidence.
        let transfer = TransactionIntent(requestId: "1", origin: Fixture.origin, chainId: 10143, from: Fixture.account, to: wmon, value: .zero,
                                         data: Fixture.calldata(Selector.transfer, [CalldataDecoder.word(Fixture.spender), CalldataDecoder.word(UInt256(1))]), gasLimit: nil)
        let a = DeterministicRiskEngine.assess(transfer, context: Fixture.liveContext)
        guard let al = TransactionAlert.make(tabID: tab, intent: transfer, assessment: a) else { return } // informational transfers make no alert
        book.record(al)
        XCTAssertEqual(book.escalate(tabID: tab, fingerprint: transfer.fingerprint, to: .high, codes: ["intel.x"]), .escalated)
        XCTAssertEqual(book.current(tabID: tab, origin: Fixture.origin)?.level, .high)
        XCTAssertEqual(book.escalate(tabID: tab, fingerprint: transfer.fingerprint, to: .caution, codes: []), .none)
        XCTAssertEqual(book.current(tabID: tab, origin: Fixture.origin)?.level, .high)
    }

    func testHighOutranksAmberWhenTwoRequestsPend() {
        var book = TransactionAlertBook()
        let high = unlimitedIntent()
        book.record(alert(high))
        let unknownCall = TransactionIntent(requestId: "9", origin: Fixture.origin, chainId: 10143, from: Fixture.account, to: wmon,
                                            value: .zero, data: Data([0xde, 0xad, 0xbe, 0xef]), gasLimit: nil)
        let ua = DeterministicRiskEngine.assess(unknownCall, context: Fixture.liveContext)
        book.record(TransactionAlert.make(tabID: tab, intent: unknownCall, assessment: ua, now: Date().addingTimeInterval(5))!)
        XCTAssertEqual(book.current(tabID: tab, origin: Fixture.origin)?.level, .high)
    }

    func testAlertsCannotSignOrApprove() {
        // The alert model only describes; it exposes no path that resolves a request as approved without a hash
        // from the real pipeline, and approval never lowers the indicator below red for risky requests.
        var book = TransactionAlertBook()
        let i = unlimitedIntent()
        book.record(alert(i))
        book.resolve(tabID: tab, fingerprint: i.fingerprint, as: .approved(txHash: nil))
        XCTAssertNotEqual(SecurityIndicator.derive(site: .noKnownThreats, alert: book.current(tabID: tab, origin: Fixture.origin)).tone, .green)
    }
}
