import MonaGuard

// Replays the exact request NebulaDrop's "Claim Rewards" button sends (see Demo/NebulaDrop.html), plus a bounded
// approval and a revoke for comparison. Offline: no RPC, no AI, no keys.
let wmon = "0xFb8bf4c1CC7a94c73D209a149eA2AbEa852BC541"   // canonical Wrapped MON, Monad Testnet
let account = "0x1111111111111111111111111111111111111111" // placeholder; nothing is signed
let spender = String(repeating: "0", count: 24) + "000000000000000000000000000000000000dead"
let approve = "0x095ea7b3" + spender

let cases: [(String, String)] = [
    ("NebulaDrop \"Claim Rewards\" (unlimited approval)", approve + String(repeating: "f", count: 64)),
    ("Limited approval (5 WMON)", approve + String(repeating: "0", count: 48) + "4563918244f40000"),
    ("Revoke (approve spender, 0)", approve + String(repeating: "0", count: 64)),
]

for (title, data) in cases {
    print("\n=== \(title) ===")
    do {
        let r = try MonaGuardEngine.review(origin: MonaGuardEngine.nebulaDropOrigin, from: account, to: wmon, data: data)
        print("Risk:      \(r.level)\nHeadline:  \(r.headline)\nPlain:     \(r.plainEnglish)")
        r.findings.forEach { print("  • \($0)") }
        if let i = r.interruption {
            print("\n  ┌ RED INTERRUPTION: \(i.headline)\n  │ \(i.explanation)")
            if let p = i.promised { print("  │ PROMISED: \(p)") }
            print("  │ ACTUAL:   \(i.actual)")
            if let s = i.persistence { print("  │ \(s)") }
            print("  │ Token \(i.tokenContract ?? "?") · Spender \(i.spender ?? "?")\n  └ Buttons: [Reject transaction]  (Review technical details)")
        } else {
            print("  (no red interruption: not HIGH risk)")
        }
    } catch {
        print("Input error: \(error)")
    }
}
