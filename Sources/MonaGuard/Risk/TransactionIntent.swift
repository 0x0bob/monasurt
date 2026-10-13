import Foundation
import CryptoKit

/// Canonical, immutable form of an `eth_sendTransaction` request. Built once from untrusted page
/// params, then frozen; its fingerprint is re-checked immediately before signing.
struct TransactionIntent: Equatable, Sendable {
    let requestId: String
    let origin: String
    let chainId: Int
    let from: Address
    /// nil only for app-internal contract deployment; page requests without `to` are rejected.
    let to: Address?
    let value: UInt256
    let data: Data
    let gasLimit: UInt256?

    static let maxCalldataBytes = 32 * 1024

    enum ValidationError: Error, Equatable, LocalizedError {
        case notAnObject
        case unexpectedField(String)
        case invalidField(String)
        case missingRecipient
        case wrongAccount
        case wrongChain(String)
        case calldataTooLarge
        case unsupportedType

        var errorDescription: String? {
            switch self {
            case .notAnObject: return "Transaction must be a single object"
            case .unexpectedField(let f): return "Unsupported transaction field: \(f)"
            case .invalidField(let f): return "Invalid transaction field: \(f)"
            case .missingRecipient: return "Contract creation is not supported"
            case .wrongAccount: return "From address is not the connected account"
            case .wrongChain(let c): return "Chain \(c) is not allowed; only Monad Testnet (10143)"
            case .calldataTooLarge: return "Calldata exceeds \(TransactionIntent.maxCalldataBytes) bytes"
            case .unsupportedType: return "Only legacy or EIP-1559 transactions are supported"
            }
        }
    }

    /// Fields a dApp may send. Fee fields are accepted but ignored (the wallet SDK prices gas);
    /// anything else (e.g. nonce, accessList, authorizationList) is rejected rather than silently dropped.
    private static let allowedKeys: Set<String> = ["from", "to", "value", "data", "input", "gas", "gasLimit", "chainId", "type", "gasPrice", "maxFeePerGas", "maxPriorityFeePerGas"]

    init(requestId: String, origin: String, params: Any, account: Address) throws {
        guard let list = params as? [Any], list.count == 1, let tx = list[0] as? [String: Any] else {
            throw ValidationError.notAnObject
        }
        for key in tx.keys where !Self.allowedKeys.contains(key) {
            throw ValidationError.unexpectedField(key)
        }
        guard let fromString = tx["from"] as? String, let from = Address(fromString) else {
            throw ValidationError.invalidField("from")
        }
        guard from == account else { throw ValidationError.wrongAccount }
        guard let toRaw = tx["to"], !(toRaw is NSNull) else { throw ValidationError.missingRecipient }
        guard let toString = toRaw as? String, let to = Address(toString) else { throw ValidationError.invalidField("to") }

        let value: UInt256
        if let v = tx["value"] {
            guard let s = v as? String, let parsed = UInt256(hex: s) else { throw ValidationError.invalidField("value") }
            value = parsed
        } else {
            value = .zero
        }

        if tx["data"] != nil && tx["input"] != nil && (tx["data"] as? String)?.lowercased() != (tx["input"] as? String)?.lowercased() {
            throw ValidationError.invalidField("data")
        }
        let data: Data
        if let d = tx["data"] ?? tx["input"] {
            guard let s = d as? String else { throw ValidationError.invalidField("data") }
            guard s.count <= 2 + Self.maxCalldataBytes * 2 else { throw ValidationError.calldataTooLarge }
            guard let bytes = Hex.decode(s) else { throw ValidationError.invalidField("data") }
            data = bytes
        } else {
            data = Data()
        }

        if let c = tx["chainId"] {
            guard let s = c as? String, let parsed = UInt256(hex: s) else { throw ValidationError.invalidField("chainId") }
            guard parsed == UInt256(UInt64(MonadNetwork.testnetChainId)) else { throw ValidationError.wrongChain(s) }
        }
        if let t = tx["type"] {
            guard let s = t as? String, ["0x0", "0x00", "0x2", "0x02"].contains(s.lowercased()) else { throw ValidationError.unsupportedType }
        }
        for key in ["gasPrice", "maxFeePerGas", "maxPriorityFeePerGas"] {
            if let f = tx[key] {
                guard let s = f as? String, UInt256(hex: s) != nil else { throw ValidationError.invalidField(key) }
            }
        }
        // A site-supplied gas limit is validated but not used: Monad charges for the gas limit, so a page
        // could inflate fees. The wallet SDK estimates gas instead.
        if let g = tx["gas"] ?? tx["gasLimit"] {
            guard let s = g as? String, let parsed = UInt256(hex: s), !parsed.isZero, parsed < UInt256(30_000_000) else {
                throw ValidationError.invalidField("gas")
            }
        }

        self.init(requestId: requestId, origin: origin, chainId: MonadNetwork.testnetChainId, from: from, to: to, value: value, data: data, gasLimit: nil)
    }

    init(requestId: String, origin: String, chainId: Int, from: Address, to: Address?, value: UInt256, data: Data, gasLimit: UInt256?) {
        self.requestId = requestId
        self.origin = origin
        self.chainId = chainId
        self.from = from
        self.to = to
        self.value = value
        self.data = data
        self.gasLimit = gasLimit
    }

    /// Length-prefixed canonical encoding: unambiguous for any field contents.
    var canonicalBytes: Data {
        var out = Data("shield-intent-v1".utf8)
        func field(_ d: Data) {
            var len = UInt32(d.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(d)
        }
        field(Data(origin.utf8))
        field(Data(String(chainId).utf8))
        field(Data(from.lowercased.utf8))
        field(Data((to?.lowercased ?? "create").utf8))
        field(value.bigEndianBytes)
        field(data)
        field(gasLimit?.bigEndianBytes ?? Data())
        return out
    }

    /// SHA-256 over the canonical encoding (request id excluded so identical requests fingerprint equally).
    var fingerprint: String {
        SHA256.hash(data: canonicalBytes).map { String(format: "%02x", $0) }.joined()
    }

    var shortFingerprint: String {
        let f = fingerprint
        return "\(f.prefix(8))…\(f.suffix(8))"
    }
}
