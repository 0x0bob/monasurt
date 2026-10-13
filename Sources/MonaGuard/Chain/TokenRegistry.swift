import Foundation

/// Testnet tokens whose symbol and decimals were read on-chain (eth_call, 2026-10-13). Balances are always
/// fetched live with balanceOf; nothing here is a price or a claim of legitimacy.
struct KnownToken: Identifiable, Hashable, Sendable {
    let symbol: String
    let decimals: Int
    let address: Address
    let note: String
    var id: String { address.lowercased }

    static let testnet: [KnownToken] = [
        KnownToken(symbol: "WMON", decimals: 18, address: Address("0xFb8bf4c1CC7a94c73D209a149eA2AbEa852BC541")!, note: "Canonical Wrapped MON (Monad docs)"),
        KnownToken(symbol: "WMON", decimals: 18, address: Address("0x97B3070F9Da6C002343862b35E68Bd8e22608943")!, note: "PuddleSwap's WMON (different contract)"),
        KnownToken(symbol: "USDC", decimals: 6, address: Address("0x534b2f3A21130d7a60830c2Df862319e593943A3")!, note: "Test USDC (Monad token list)"),
        KnownToken(symbol: "USDT", decimals: 6, address: Address("0x1314b22df27BDcD4F8D11a0f4185943e55748917")!, note: "Test USDT (PuddleSwap)"),
        KnownToken(symbol: "WETH", decimals: 18, address: Address("0x45477f4709771331db81944A5E20eF95Bc7BA2D7")!, note: "Test WETH (Monad token list)"),
    ]

    /// Contracts MonaSurf can name in reviews. Naming is informational only and never lowers a risk level.
    static let labels: [Address: String] = [
        Address("0x430c23895c8D44883526e3E0B09327dAD8766660")!: "PuddleSwap router (address from PuddleSwap's app; unaudited)",
    ]
}
