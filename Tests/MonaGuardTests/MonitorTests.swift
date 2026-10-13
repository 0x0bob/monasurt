import XCTest
@testable import MonaGuard

final class URLHeuristicsTests: XCTestCase {
    private func codes(_ s: String) -> Set<URLHeuristics.Finding.Code> { Set(URLHeuristics.analyze(URL(string: s)!).map(\.code)) }

    func testLegitimateSitesHaveNoFindings() {
        for s in ["https://app.puddleswap.org/", "https://faucet.monad.xyz/", "https://testnet.monadscan.com/tx/0x1", "https://docs.monad.xyz/", "https://duckduckgo.com/?q=monad"] {
            XCTAssertTrue(URLHeuristics.analyze(URL(string: s)!).isEmpty, s)
        }
    }

    func testPhishingPatterns() {
        XCTAssertTrue(codes("https://app.puddleswap.org.evil.com/").contains(.brandInOtherDomain))
        XCTAssertTrue(codes("https://puddleswap-airdrop.xyz/").contains(.brandInOtherDomain))
        XCTAssertTrue(codes("https://app.puddlesvvap.org/").contains(.lookalike))
        XCTAssertFalse(codes("https://monadd.xyz/").isDisjoint(with: [.lookalike, .brandInOtherDomain]))
        XCTAssertTrue(codes("https://xn--mnad-6na.xyz/").contains(.punycode))
        XCTAssertTrue(codes("https://192.168.0.10/login").contains(.ipLiteralHost))
        XCTAssertTrue(codes("https://claim-rewards.io/connect-wallet").contains(.lureKeyword))
        XCTAssertTrue(codes("https://faucet.monad.xyz@evil.example/").contains(.credentialsInURL))
    }

    func testBrandLookalikesAreHighRisk() {
        let f = URLHeuristics.analyze(URL(string: "https://app.puddleswap.org.evil.com/")!)
        XCTAssertTrue(f.contains { $0.level == .high })
    }
}

final class SiteVerdictTests: XCTestCase {
    private func evidence(_ mutate: (inout SiteEvidence) -> Void = { _ in }) -> SiteEvidence {
        var e = SiteEvidence(origin: "https://app.puddleswap.org", loading: false, isHTTPS: true, isBundledDemo: false, hasOnlySecureContent: true,
                             urlFindings: [], reputation: .notConfigured, walletEnabled: true)
        mutate(&e); return e
    }

    func testCheckingWhileLoading() { XCTAssertEqual(SiteVerdict.derive(evidence { $0.loading = true }).status, .checking) }

    func testCleanHTTPSWithNoFindingsIsNoKnownThreatsNotSafe() {
        let v = SiteVerdict.derive(evidence())
        XCTAssertEqual(v.status, .noKnownThreats)
        for claim in ["all safe", "guaranteed", "verified secure"] { XCTAssertFalse(v.details.lowercased().contains(claim)) }
        XCTAssertTrue(v.details.contains("does not prove the site is safe"))
    }

    func testReputationFailureNeverGreen() {
        XCTAssertEqual(SiteVerdict.derive(evidence { $0.reputation = .failed("timeout") }).status, .unknown)
    }

    func testReputationFlaggedIsHigh() {
        XCTAssertEqual(SiteVerdict.derive(evidence { $0.reputation = .flagged(source: "List", reason: "phishing") }).status, .highRisk)
    }

    func testInsecureAndHeuristics() {
        XCTAssertEqual(SiteVerdict.derive(evidence { $0.hasOnlySecureContent = false }).status, .caution)
        XCTAssertEqual(SiteVerdict.derive(evidence { $0.isHTTPS = false }).status, .unknown)
        let lookalike = URLHeuristics.analyze(URL(string: "https://app.puddlesvvap.org/")!)
        XCTAssertEqual(SiteVerdict.derive(evidence { $0.urlFindings = lookalike }).status, .highRisk)
    }

    func testAlertGateDeduplicates() {
        var g = AlertGate(cooldown: 600)
        let t = Date()
        XCTAssertTrue(g.shouldAlert(origin: "o", key: "unlimitedApproval", now: t))
        XCTAssertFalse(g.shouldAlert(origin: "o", key: "unlimitedApproval", now: t.addingTimeInterval(5)))
        XCTAssertTrue(g.shouldAlert(origin: "o2", key: "unlimitedApproval", now: t.addingTimeInterval(5)))
        XCTAssertTrue(g.shouldAlert(origin: "o", key: "unlimitedApproval", now: t.addingTimeInterval(601)))
    }
}
