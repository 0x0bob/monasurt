import Foundation

/// The only network MonaSurf signs on. Mainnet (143) is listed for documentation and is never selectable.
enum MonadNetwork {
    static let testnetChainId = 10143
    static let testnetChainIdHex = "0x279f"
    static let testnetName = "Monad Testnet"
    static let testnetRPC = URL(string: "https://testnet-rpc.monad.xyz")!
    static let testnetExplorer = URL(string: "https://testnet.monadscan.com")!
    static let nativeSymbol = "MON"
    static let nativeDecimals = 18
    /// Canonical Wrapped MON on testnet (docs.monad.xyz, checked on-chain 2026-10-13: symbol WMON, 18 decimals).
    static let wmon = Address("0xFb8bf4c1CC7a94c73D209a149eA2AbEa852BC541")!

    /// Documented only. `isSigningAllowed` returns false for it.
    static let mainnetChainId = 143

    static func isSigningAllowed(chainId: Int) -> Bool { chainId == testnetChainId }

    static func explorerURL(txHash: String) -> URL? {
        guard Hex.isTxHash(txHash) else { return nil }
        return testnetExplorer.appendingPathComponent("tx").appendingPathComponent(txHash.lowercased())
    }

    static func explorerURL(address: String) -> URL? {
        guard let a = Address(address) else { return nil }
        return testnetExplorer.appendingPathComponent("address").appendingPathComponent(a.lowercased)
    }
}

enum Hex {
    static func isHexString(_ s: String, allowEmpty: Bool = true) -> Bool {
        guard s.hasPrefix("0x") else { return false }
        let body = s.dropFirst(2)
        if body.isEmpty { return allowEmpty }
        return body.allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    static func isTxHash(_ s: String) -> Bool {
        s.count == 66 && isHexString(s, allowEmpty: false)
    }

    /// Decodes 0x-prefixed, even-length hex into bytes.
    static func decode(_ s: String) -> Data? {
        guard isHexString(s) else { return nil }
        let body = Array(s.utf8.dropFirst(2))
        guard body.count % 2 == 0 else { return nil }
        var out = Data(capacity: body.count / 2)
        var i = 0
        while i < body.count {
            guard let hi = nibble(body[i]), let lo = nibble(body[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    static func encode(_ data: Data) -> String {
        "0x" + data.map { String(format: "%02x", $0) }.joined()
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: return nil
        }
    }
}

/// A 20-byte EVM address. Stored lowercase; checksum casing in input is accepted but not verified
/// (MonaSurf has no keccak implementation; addresses are always displayed in full on review screens).
struct Address: Hashable, Sendable, CustomStringConvertible {
    let lowercased: String

    init?(_ string: String) {
        guard string.count == 42, Hex.isHexString(string, allowEmpty: false) else { return nil }
        lowercased = string.lowercased()
    }

    init(word: Data) {
        precondition(word.count == 20)
        lowercased = Hex.encode(word)
    }

    var description: String { lowercased }

    var short: String { "\(lowercased.prefix(6))…\(lowercased.suffix(4))" }

    static let zero = Address("0x0000000000000000000000000000000000000000")!
}
