import Foundation

/// Lifecycle of one wallet request as far as alerts are concerned. Derived from the review's real phase.
enum AlertRequestState: Equatable, Sendable {
    case pendingReview
    case rejected
    case invalidated(reason: String)       // navigation, expiry, backgrounding, or a failure reported by the pipeline
    case approved(txHash: String?)         // the user signed after the review; outcome is the real broadcast

    var isActive: Bool { self == .pendingReview }
}

/// A deterministic alert about one wallet request (never produced by AI). Keyed by tab and request fingerprint,
/// so re-renders and repeated callbacks for the same request update one alert instead of adding new ones.
struct TransactionAlert: Identifiable, Equatable, Sendable {
    var id: String { "\(tabID.uuidString)|\(fingerprint)" }
    let tabID: UUID
    let origin: String
    let fingerprint: String
    private(set) var level: RiskLevel
    private(set) var codes: [String]
    let title: String
    let summary: String
    /// The top deterministic finding, for the expandable details.
    let detail: String
    private(set) var state: AlertRequestState
    let createdAt: Date
    private(set) var updatedAt: Date
    /// True when remote evidence raised the level after the alert was created.
    private(set) var escalated = false
    var dismissed = false

    /// Raises the level (never lowers it) and merges finding codes.
    mutating func escalate(to newLevel: RiskLevel, codes more: [String], at date: Date) -> Bool {
        guard newLevel > level else {
            codes = Array(Set(codes + more)).sorted()
            return false
        }
        level = newLevel
        codes = Array(Set(codes + more)).sorted()
        escalated = true
        updatedAt = date
        return true
    }

    mutating func resolve(_ s: AlertRequestState, at date: Date) {
        // A resolved request stays resolved; only a pending one can change state.
        guard state == .pendingReview else { return }
        state = s
        updatedAt = date
    }

    /// Short state line for the alert card.
    var stateText: String {
        switch state {
        case .pendingReview: return "Awaiting your decision in the review"
        case .rejected: return "Rejected · nothing signed or broadcast"
        case .invalidated(let reason): return "Not completed (\(reason))"
        case .approved(let hash): return hash.map { "You approved it · broadcast \(String($0.prefix(10)))…" } ?? "You approved it"
        }
    }

    /// Builds the alert from the deterministic assessment. Only HIGH and UNKNOWN requests (and CAUTION, as amber)
    /// produce alerts; informational requests do not.
    static func make(tabID: UUID, intent: TransactionIntent, assessment a: RiskAssessment, now: Date = Date()) -> TransactionAlert? {
        guard a.level >= .caution else { return nil }
        let token = intent.to.flatMap { to in KnownToken.testnet.first { $0.address == to }?.symbol } ?? intent.to.map { "token \($0.short)" } ?? "a contract"
        var title = a.headline
        var summary = a.plainEnglish
        switch a.decoded {
        case .erc20Approve(let spender, _) where a.findings.contains(where: { $0.code == .unlimitedApproval }):
            title = "Dangerous wallet permission"
            summary = "This site is requesting unlimited access to your \(token) tokens. Spender: \(spender.short)."
        case .setApprovalForAll(let op, true):
            title = "Dangerous wallet permission"
            summary = "This site is requesting control of all your items in \(token). Operator: \(op.short)."
        default:
            break
        }
        return TransactionAlert(tabID: tabID, origin: intent.origin, fingerprint: intent.fingerprint, level: a.level,
                                codes: a.findings.map(\.code.rawValue).sorted(), title: title, summary: summary,
                                detail: a.findings.max { $0.level < $1.level }?.detail ?? a.plainEnglish,
                                state: .pendingReview, createdAt: now, updatedAt: now)
    }
}

/// All transaction alerts for the session. Pure value type so the lifecycle is unit-testable.
struct TransactionAlertBook: Equatable, Sendable {
    private(set) var alerts: [String: TransactionAlert] = [:]

    enum Change: Equatable { case none, created, escalated, updated }

    /// Records a new alert, or updates the existing one for the same (tab, fingerprint).
    @discardableResult
    mutating func record(_ alert: TransactionAlert) -> Change {
        if var existing = alerts[alert.id] {
            let raised = existing.escalate(to: alert.level, codes: alert.codes, at: alert.updatedAt)
            alerts[alert.id] = existing
            return raised ? .escalated : .none
        }
        alerts[alert.id] = alert
        return .created
    }

    @discardableResult
    mutating func escalate(tabID: UUID, fingerprint: String, to level: RiskLevel, codes: [String], now: Date = Date()) -> Change {
        let key = "\(tabID.uuidString)|\(fingerprint)"
        guard var a = alerts[key] else { return .none }
        let raised = a.escalate(to: level, codes: codes, at: now)
        alerts[key] = a
        return raised ? .escalated : .none
    }

    @discardableResult
    mutating func resolve(tabID: UUID, fingerprint: String, as state: AlertRequestState, now: Date = Date()) -> Change {
        let key = "\(tabID.uuidString)|\(fingerprint)"
        guard var a = alerts[key], a.state.isActive else { return .none }
        a.resolve(state, at: now)
        a.dismissed = false
        alerts[key] = a
        return .updated
    }

    mutating func dismiss(id: String) { alerts[id]?.dismissed = true }

    /// The tab now shows `origin`: alerts from other origins in this tab no longer apply to what is on screen.
    /// Pending ones are marked invalidated (the review itself is cancelled by the existing navigation rules).
    mutating func navigated(tabID: UUID, to origin: String?, now: Date = Date()) {
        for (k, var a) in alerts where a.tabID == tabID && a.origin != origin {
            if a.state.isActive { a.resolve(.invalidated(reason: "left the page"), at: now) }
            a.dismissed = true
            alerts[k] = a
        }
    }

    mutating func tabClosed(_ tabID: UUID) { alerts = alerts.filter { $0.value.tabID != tabID } }

    /// The single alert to show for this tab and origin: an active one first (highest level, newest), otherwise the
    /// newest resolved one that the user has not dismissed.
    func current(tabID: UUID, origin: String?) -> TransactionAlert? {
        let mine = alerts.values.filter { $0.tabID == tabID && $0.origin == origin }
        if let active = mine.filter({ $0.state.isActive }).max(by: { ($0.level, $0.updatedAt) < ($1.level, $1.updatedAt) }) { return active }
        return mine.filter { !$0.dismissed }.max { $0.updatedAt < $1.updatedAt }
    }
}

/// What the browser's main security indicator shows. An active risky request always outranks routine site checks.
struct SecurityIndicator: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case checking, green, neutral, amber, red }
    let tone: Tone
    let title: String
    let icon: String

    static func derive(site: SiteStatus?, alert: TransactionAlert?) -> SecurityIndicator {
        let siteIndicator = derive(site: site)
        if let a = alert, !a.state.isActive, siteIndicator.tone == .red {
            // A resolved request never hides a red site warning (e.g. the deceptive training page).
            return siteIndicator
        }
        if let a = alert {
            switch a.state {
            case .pendingReview:
                switch a.level {
                case .high: return .init(tone: .red, title: "High-risk action", icon: "exclamationmark.octagon.fill")
                case .unknown: return .init(tone: .amber, title: "Unable to verify", icon: "questionmark.diamond.fill")
                default: return .init(tone: .amber, title: "Review recommended", icon: "exclamationmark.shield.fill")
                }
            case .approved:
                // Evidence of a risky approval is kept; it is never turned into a green result.
                if a.level >= .unknown { return .init(tone: .red, title: "Risky request approved", icon: "exclamationmark.octagon.fill") }
            case .rejected:
                if !a.dismissed, a.level >= .unknown { return .init(tone: .amber, title: "Risky request rejected", icon: "hand.raised.fill") }
            case .invalidated:
                if !a.dismissed, a.level >= .unknown { return .init(tone: .amber, title: "Risky request cancelled", icon: "hand.raised.fill") }
            }
        }
        return siteIndicator
    }

    static func derive(site: SiteStatus?) -> SecurityIndicator {
        switch site {
        case nil, .checking?: return .init(tone: .checking, title: "Checking site…", icon: "shield")
        case .noKnownThreats?: return .init(tone: .green, title: "No known URL threats", icon: "checkmark.shield.fill")
        case .caution?: return .init(tone: .amber, title: "Review recommended", icon: "exclamationmark.shield.fill")
        case .unknown?: return .init(tone: .amber, title: "Unable to verify", icon: "questionmark.diamond.fill")
        case .highRisk?: return .init(tone: .red, title: "Suspicious site", icon: "xmark.shield.fill")
        case .deceptiveDemo?: return .init(tone: .red, title: "Security demo: deceptive dApp", icon: "exclamationmark.octagon.fill")
        }
    }
}
