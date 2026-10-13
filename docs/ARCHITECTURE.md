# Mona Guard architecture

Mona Guard is the security engine inside the MonaSurf iOS browser. This document covers the part published in this repository and how it connects to the private app.

## Design principles

1. **Decide from facts, not appearances.** The verdict is computed from the decoded transaction (target, selector, arguments, value, chain). Page text, styling and the site's claims play no part.
2. **No “safe” level.** `RiskLevel` has `informational`, `caution`, `unknown` and `high`. The best possible result is “No identified warning”.
3. **Fail closed.** Unknown selectors, malformed ABI, missing on-chain context and failed simulations all produce `unknown`, never a lower level.
4. **Escalate only.** Later evidence, such as live RPC data or remote intelligence in the app, can raise a level but never lower it. AI output never changes a level.
5. **The website is untrusted.** Labels such as “training demo” come only from native constants (`DemoOrigins`, `TrainingDemo`), never from page content.
6. **Pure and testable.** Everything here is value types and pure functions with Foundation and CryptoKit only. No UI, no networking, no keys.

## Components

### `TransactionIntent` (Risk)
Strict parser for `eth_sendTransaction` params from untrusted JavaScript:
- It rejects unknown fields, conflicting `data`/`input`, wrong accounts, any chain other than 10143, contract creation and calldata over 32 KB.
- It ignores a gas limit supplied by the site.

The parsed intent is immutable, and its **fingerprint** is the SHA-256 of a canonical byte encoding. In the app, the fingerprint is re-checked right before signing, so the signed bytes are exactly the reviewed bytes.

### `CalldataDecoder` (Risk)
Strict ABI decoding for the supported selectors:
- ERC-20 `approve`, `transfer` and `transferFrom`
- `setApprovalForAll`
- Uniswap-V2-style swaps
- WMON `deposit` and `withdraw`

Non-canonical encodings (dirty address high bits, bools other than 0/1, short or trailing bytes, malformed dynamic arrays) decode to `.malformed`. Anything unrecognised decodes to `.unknown(selector:)`.

### `DeterministicRiskEngine` (Risk)
`assess(intent, context:)` turns the decoded call plus optional `OnchainContext` into a `RiskAssessment`: level, headline, plain-English summary, findings and fingerprint. The main rules:

| Request | Level |
|---|---|
| `approve` with MAX or effectively unlimited amount | HIGH |
| `setApprovalForAll(op, true)` | HIGH |
| Swap paying out to another recipient | HIGH |
| Bounded `approve`, `transfer`, native transfer | CAUTION (raised to UNKNOWN when context is missing) |
| `approve(spender, 0)` (revoke) | informational finding; overall level depends on context |
| Unknown or malformed calldata, target without code, failed simulation | UNKNOWN |
| No on-chain context available | UNKNOWN (fail closed) |

Token symbols read from contracts are sanitised (printable ASCII, max 12 characters) before display.

### `SecurityInterruption` and `TrainingDemo` (Risk)
For **HIGH** requests only, `SecurityInterruption.make` builds the content of the full-screen red warning:
- headline
- explanation
- **promised** vs **actual** action
- persistence warning
- exact token contract and spender

The "promised" line is filled in only for bundled training pages, from `TrainingDemo` native metadata. For ordinary sites the engine never invents what a site claimed. The wording avoids overclaiming (it does not say "drained" or "all your assets").

In the app, this screen is drawn from the **preliminary, network-free assessment**, so it appears at once and cannot be delayed or weakened by RPC, intelligence or AI calls.

### `AllowanceCalls` (Risk)
Calldata builders for the revoke flow:
- `approve(spender, 0)` on the same token
- `allowance(owner, spender)`, used to verify the revoke on-chain afterwards

### `TransactionAlert`, `TransactionAlertBook`, `SecurityIndicator` (Monitor)
Request alerts are kept **separate** from the site verdict, because a risky request is not proof that the site is malicious:
- Alerts are keyed by `tab|fingerprint`, so repeated events update one alert.
- Their level only goes up.
- Their lifecycle is `pendingReview → rejected | invalidated | approved`.

`SecurityIndicator.derive(site:alert:)` produces the single badge shown in the browser and chat:
- A pending HIGH request is red, even on a site with a green verdict.
- An approved risky request stays red.
- A rejected or cancelled request is amber and never green.
- A resolved request never hides a red site warning.

### `SiteVerdict`, `URLHeuristics` (Monitor)
Lightweight site checks:
- HTTPS and mixed content
- URL phishing patterns, such as brand look-alikes, credentials in the URL and IP hosts
- an optional reputation result

The best site status is “No known URL threats”, not “safe”. A failed reputation check never shows green.

### `MonaGuardEngine` (public API)
A small read-only facade, `review(origin:from:to:data:valueWei:)`, used by the `nebuladrop-check` command. It returns plain strings and never signs.

## Trust boundaries in the full app

```text
 ┌──────────── untrusted ────────────┐   ┌──────────────────── MonaSurf (trusted) ─────────────────────┐
 │ Website JavaScript (WKWebView)    │──▶│ EIP-1193 bridge + origin/top-frame checks        (private)  │
 │ Page text, styling, claims        │   │ TransactionIntent → CalldataDecoder → RiskEngine  (public)  │
 └───────────────────────────────────┘   │ SecurityInterruption / alerts / indicator         (public)  │
                                         │ Review UI → confirm → Face ID → fingerprint check (private) │
 ┌──────────── advisory only ────────┐   │ Wallet / Keychain / signer / broadcast            (private) │
 │ Live RPC enrichment (can raise)   │──▶│                                                             │
 │ AI explanation (cannot change     │   └─────────────────────────────────────────────────────────────┘
 │ levels, cannot sign)              │
 └───────────────────────────────────┘
```

## NebulaDrop request, step by step

1. NebulaDrop (origin `shield-demo://nebuladrop`) calls `eth_sendTransaction` with `to = WMON` and `data = 0x095ea7b3 | pad(0x…dEaD) | ff…ff`.
2. `TransactionIntent` validates and fingerprints the request.
3. `CalldataDecoder` → `.erc20Approve(spender: 0x…dEaD, amount: MAX)`.
4. `DeterministicRiskEngine` produces the finding `unlimitedApproval` and the level **HIGH**.
5. `SecurityInterruption.make` returns “STOP. THIS IS NOT A REWARD CLAIM.”, promised “Claim 5,000 NEB (fictional reward)” and actual “Unlimited WMON approval”.
6. `TransactionAlert` is created as HIGH and pending, and `SecurityIndicator` shows red “High-risk action”.
7. If the user taps **Reject transaction**, the site receives EIP-1193 error 4001, nothing is signed, and the alert becomes “Risky request rejected”. That state is amber, never green.

Steps 2–5 can be reproduced with `swift run nebuladrop-check`. Steps 2–6 and the rejected-state rules in step 7 are covered by `swift test`. Delivering error 4001 to the page happens in the private app.

## Known limitations
See the *Limitations* section of the [README](../README.md).
