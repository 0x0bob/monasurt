import Foundation

/// Trusted, app-bundled knowledge about training pages. Comes only from native configuration, never from page content.
enum TrainingDemo {
    struct Info: Equatable, Sendable {
        let label: String
        let message: String
        /// What the page advertises to the user (it is our own bundled page, so this is known, not guessed).
        let promisedAction: String
        let promiseIsRewardClaim: Bool
    }

    static func info(for origin: String?) -> Info? {
        guard origin == DemoOrigins.nebulaOrigin else { return nil }
        return Info(label: "SECURITY DEMO: DECEPTIVE DAPP",
                    message: "This fictional site advertises rewards but contains a simulated dangerous wallet-permission flow.",
                    promisedAction: "Claim 5,000 NEB (fictional reward)",
                    promiseIsRewardClaim: true)
    }
}

/// Content of the full-screen red interruption shown for HIGH-risk requests. Built only from the decoded request
/// and the deterministic assessment (plus trusted demo metadata for the bundled training page). No AI, no network.
struct SecurityInterruption: Equatable, Sendable {
    let headline: String
    let explanation: String
    let promised: String?
    let actual: String
    let persistence: String?
    let tokenLabel: String?
    let tokenContract: String?
    let spender: String?

    static func make(intent: TransactionIntent, assessment a: RiskAssessment) -> SecurityInterruption? {
        guard a.level == .high else { return nil }
        let demo = TrainingDemo.info(for: intent.origin)
        let promised = demo?.promisedAction
        let token = intent.to.flatMap { to in KnownToken.testnet.first { $0.address == to }?.symbol }
        let tokenName = token ?? "this token"

        switch a.decoded {
        case .erc20Approve(let spender, let amount) where a.findings.contains(where: { $0.code == .unlimitedApproval }):
            let amountText = amount == .max ? "Unlimited" : "Effectively unlimited"
            let lead = demo?.promiseIsRewardClaim == true
                ? "This website promised you rewards, but it is asking for unlimited permission to spend your \(tokenName) tokens."
                : "This website is asking for unlimited permission to spend your \(tokenName) tokens."
            return SecurityInterruption(
                headline: demo?.promiseIsRewardClaim == true ? "STOP. THIS IS NOT A REWARD CLAIM." : "STOP. CHECK THIS PERMISSION.",
                explanation: lead,
                promised: promised,
                actual: "\(amountText) \(token ?? "token") approval",
                persistence: "Once approved, this permission can remain active until revoked. The spender could potentially transfer approved \(tokenName) later without requesting another signature.",
                tokenLabel: token, tokenContract: intent.to?.lowercased, spender: spender.lowercased)
        case .setApprovalForAll(let op, true):
            return SecurityInterruption(
                headline: "STOP. CHECK THIS PERMISSION.",
                explanation: "This website is asking for control of every item you hold in this collection contract.",
                promised: promised, actual: "Approval for all items (setApprovalForAll)",
                persistence: "Once approved, the operator can transfer these items later without another signature, until revoked.",
                tokenLabel: token, tokenContract: intent.to?.lowercased, spender: op.lowercased)
        default:
            return SecurityInterruption(headline: "STOP. HIGH-RISK REQUEST.", explanation: a.plainEnglish, promised: promised,
                                        actual: a.headline, persistence: nil, tokenLabel: token,
                                        tokenContract: intent.to?.lowercased, spender: nil)
        }
    }
}

/// ERC-20 allowance helpers used by the revoke flow.
enum AllowanceCalls {
    /// approve(spender, 0) on the same token: the standard revocation.
    static func revokeCalldata(spender: Address) -> Data {
        CalldataDecoder.encode(selector: Selector.approve, words: [CalldataDecoder.word(spender), CalldataDecoder.word(UInt256.zero)])
    }

    /// allowance(owner, spender)
    static func allowanceCalldata(owner: Address, spender: Address) -> Data {
        CalldataDecoder.encode(selector: "0xdd62ed3e", words: [CalldataDecoder.word(owner), CalldataDecoder.word(spender)])
    }

    /// Spenders MonaSurf knows about: the demo's inert burn address and labelled contracts.
    static let knownSpenders: [Address] = [Address("0x000000000000000000000000000000000000dEaD")!] + Array(KnownToken.labels.keys)
}
