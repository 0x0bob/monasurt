import Foundation

/// Read-only public entry point for the extracted engine. It only analyses a request; there is no signing,
/// broadcasting or key handling anywhere in this package.
public enum MonaGuardEngine {
    public struct Report: Equatable, Sendable {
        public let level: String
        public let headline: String
        public let plainEnglish: String
        public let findings: [String]
        /// The full-screen red interruption, present only for HIGH-risk requests.
        public let interruption: Interruption?
        public let fingerprint: String
    }

    public struct Interruption: Equatable, Sendable {
        public let headline: String
        public let explanation: String
        public let promised: String?
        public let actual: String
        public let persistence: String?
        public let tokenContract: String?
        public let spender: String?
    }

    public enum InputError: Error, Equatable { case badAddress(String), badHex }

    /// Assesses an `eth_sendTransaction`-style request with no network access (the same "preliminary" assessment
    /// MonaSurf uses to show the red interruption instantly, before any optional enrichment).
    public static func review(origin: String, from: String, to: String, data hex: String, valueWei: UInt64 = 0) throws -> Report {
        guard let f = Address(from) else { throw InputError.badAddress(from) }
        guard let t = Address(to) else { throw InputError.badAddress(to) }
        guard let data = Hex.decode(hex) else { throw InputError.badHex }
        let intent = TransactionIntent(requestId: "cli", origin: origin, chainId: MonadNetwork.testnetChainId, from: f, to: t,
                                       value: UInt256(valueWei), data: data, gasLimit: nil)
        let a = DeterministicRiskEngine.assess(intent)
        let i = SecurityInterruption.make(intent: intent, assessment: a).map {
            Interruption(headline: $0.headline, explanation: $0.explanation, promised: $0.promised, actual: $0.actual,
                         persistence: $0.persistence, tokenContract: $0.tokenContract, spender: $0.spender)
        }
        return Report(level: a.level.label, headline: a.headline, plainEnglish: a.plainEnglish,
                      findings: a.findings.map { "[\($0.level.label)] \($0.title): \($0.detail)" },
                      interruption: i, fingerprint: a.fingerprint)
    }

    /// Origin of the bundled fictional NebulaDrop page (trusted native constant, never taken from page content).
    public static let nebulaDropOrigin = DemoOrigins.nebulaOrigin
}
