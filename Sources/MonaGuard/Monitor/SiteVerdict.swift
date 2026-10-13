import Foundation

/// The site's own status: connection, URL and reputation evidence only (never AI text, and never wallet requests,
/// which are tracked separately as `TransactionAlert`s so a risky request does not label the site itself).
enum SiteStatus: Equatable, Sendable {
    case checking
    case noKnownThreats
    case caution
    case highRisk
    case unknown
    /// App-bundled training page known (from native metadata) to simulate a deceptive dApp.
    case deceptiveDemo

    var title: String {
        switch self {
        case .checking: return "Checking site…"
        case .noKnownThreats: return "No known URL threats"
        case .caution: return "Review recommended"
        case .highRisk: return "Risk detected"
        case .unknown: return "Not fully verified"
        case .deceptiveDemo: return "Security demo: deceptive dApp"
        }
    }
}

enum ReputationResult: Equatable, Sendable {
    case notConfigured          // no reputation source enabled
    case clean(source: String)
    case flagged(source: String, reason: String)
    case failed(String)
}

struct SiteEvidence: Equatable, Sendable {
    var origin: String
    var loading: Bool
    var isHTTPS: Bool
    var isBundledDemo: Bool
    var hasOnlySecureContent: Bool
    var urlFindings: [URLHeuristics.Finding]
    var reputation: ReputationResult
    var walletEnabled: Bool
    /// Set only from native bundled-demo configuration (TrainingDemo), never from page content.
    var isTrainingDemo = false
}

struct SiteVerdict: Equatable, Sendable {
    let status: SiteStatus
    let reasons: [String]
    let checksRun: [String]

    static func derive(_ e: SiteEvidence) -> SiteVerdict {
        if e.loading { return SiteVerdict(status: .checking, reasons: [], checksRun: []) }
        if e.isTrainingDemo, let demo = TrainingDemo.info(for: e.origin) {
            return SiteVerdict(status: .deceptiveDemo, reasons: [demo.message],
                               checksRun: ["Bundled training page (MonaSurf's own configuration)"])
        }
        var checks = ["Connection security (WebKit)", "Local URL heuristics"]
        var reasons: [String] = []
        var status = SiteStatus.noKnownThreats

        func raise(_ s: SiteStatus) {
            let rank: [SiteStatus: Int] = [.noKnownThreats: 0, .caution: 1, .unknown: 2, .highRisk: 3, .deceptiveDemo: 4]
            if rank[s, default: 0] > rank[status, default: 0] { status = s }
        }

        if !e.isHTTPS && !e.isBundledDemo { raise(.unknown); reasons.append("The page is not served over HTTPS.") }
        if e.isHTTPS && !e.hasOnlySecureContent { raise(.caution); reasons.append("The page loaded insecure (HTTP) content.") }
        for f in e.urlFindings {
            raise(f.level == .high ? .highRisk : .caution)
            reasons.append(f.detail)
        }
        switch e.reputation {
        case .notConfigured: break
        case .clean(let source): checks.append("Reputation: \(source)")
        case .flagged(let source, let reason): checks.append("Reputation: \(source)"); raise(.highRisk); reasons.append("\(source) flags this site: \(reason)")
        case .failed(let why): raise(.unknown); reasons.append("Reputation check failed (\(why)), so this site is not fully verified.")
        }
        if e.walletEnabled { checks.append("Wallet requests: every request is reviewed separately") }
        return SiteVerdict(status: status, reasons: reasons, checksRun: checks)
    }

    /// Expandable details for the chat header. Deterministic; no AI involved.
    var details: String {
        var s = reasons.isEmpty ? "" : reasons.map { "• \($0)" }.joined(separator: "\n") + "\n\n"
        if status == .noKnownThreats {
            s += "None of the checks below found a problem. That does not prove the site is safe; every wallet request is still reviewed on its own.\n\n"
        }
        if !checksRun.isEmpty { s += "Checks run: \(checksRun.joined(separator: ", "))." }
        return s
    }
}

/// Deduplicates alerts: the same (origin, key) alerts at most once per cooldown window.
struct AlertGate: Sendable {
    let cooldown: TimeInterval
    private var last: [String: Date] = [:]

    init(cooldown: TimeInterval = 10 * 60) { self.cooldown = cooldown }

    mutating func shouldAlert(origin: String, key: String, now: Date = Date()) -> Bool {
        let k = origin + "|" + key
        if let t = last[k], now.timeIntervalSince(t) < cooldown { return false }
        last[k] = now
        return true
    }
}
