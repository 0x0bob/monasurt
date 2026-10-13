import Foundation

/// Ordered from least to most severe. There is deliberately no "safe" level.
enum RiskLevel: Int, Comparable, Codable, Sendable {
    case informational = 0
    case caution = 1
    case unknown = 2
    case high = 3

    static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .informational: return "No identified warning"
        case .caution: return "Caution"
        case .unknown: return "Unknown / unverified"
        case .high: return "High risk"
        }
    }

    /// HIGH and UNKNOWN default to Reject and require an explicit, testnet-only override.
    var requiresOverride: Bool { self >= .unknown }
}

struct Finding: Equatable, Identifiable, Sendable, Codable {
    enum Code: String, Codable, Sendable {
        case unlimitedApproval, largeApproval, boundedApproval, approvalRevoke
        case operatorGrant, operatorRevoke
        case tokenTransfer, tokenTransferFrom
        case nativeTransfer, nativeValueWithCall, emptyCall
        case unknownSelector, malformedCalldata
        case recipientHasNoCode, simulationFailed, simulationUnavailable, simulationPassed
        case tokenMetadataUnverified, contractDeployment
        case swap, swapToOtherRecipient, wrapNative, unwrapNative, unverifiedRouter
    }
    let code: Code
    let level: RiskLevel
    let title: String
    let detail: String
    var id: String { code.rawValue + title }
}

/// Facts read from Monad Testnet RPC. Every field is optional: nil means "not fetched / unavailable".
struct OnchainContext: Equatable, Sendable {
    var targetHasCode: Bool?
    var tokenSymbol: String?
    var tokenDecimals: Int?
    var gasEstimate: UInt256?
    var gasPrice: UInt256?
    var simulationError: String?
    var simulationAttempted = false

    static let none = OnchainContext()

    /// Token symbols come from contracts and are untrusted: keep printable ASCII, cap length.
    static func sanitizeSymbol(_ raw: String) -> String? {
        let filtered = raw.unicodeScalars.filter { $0.isASCII && $0.value >= 0x21 && $0.value <= 0x7e }
        let s = String(String.UnicodeScalarView(filtered.prefix(12)))
        return s.isEmpty ? nil : s
    }
}

struct RiskAssessment: Equatable, Sendable {
    let level: RiskLevel
    let headline: String
    let plainEnglish: String
    let findings: [Finding]
    let decoded: DecodedCall
    let fingerprint: String
}
