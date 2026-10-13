import Foundation

/// Pure function from canonical facts to a risk decision. No network, no AI, no randomness.
enum DeterministicRiskEngine {
    /// Approvals at or above 2^96-1 are treated as unlimited. Several tokens (e.g. UNI, COMP) use 2^96-1 as
    /// their "infinite" allowance, and it exceeds any realistic supply at 18 decimals.
    static let effectivelyUnlimited = UInt256(limbs: [.max, 0xFFFF_FFFF, 0, 0])

    static func assess(_ intent: TransactionIntent, context: OnchainContext = .none) -> RiskAssessment {
        guard let token = intent.to else { return assessDeployment(intent, context: context) }
        let decoded = CalldataDecoder.decode(intent.data)
        var findings: [Finding] = []
        let symbol = context.tokenSymbol.flatMap(OnchainContext.sanitizeSymbol)

        func amount(_ v: UInt256) -> String {
            if let d = context.tokenDecimals, (0...36).contains(d) {
                return "\(v.formatted(decimals: d, maxFractionDigits: d)) \(symbol ?? "tokens") (raw \(v.decimalString))"
            }
            return "\(v.decimalString) base units (token decimals unverified)"
        }
        let tokenName = symbol.map { "\($0) token (symbol reported by the contract, unverified)" } ?? "token contract \(token.lowercased)"

        var headline: String
        var plain: String

        switch decoded {
        case .none:
            if intent.value.isZero {
                findings.append(.init(code: .emptyCall, level: .informational, title: "Zero-value call with no data",
                                      detail: "Sends 0 MON and no calldata to \(token.lowercased)."))
                headline = "Empty transaction"
                plain = "This sends nothing and calls nothing. It still costs gas."
            } else {
                findings.append(.init(code: .nativeTransfer, level: .caution, title: "Sends \(intent.value.formatted(decimals: 18, maxFractionDigits: 18)) MON",
                                      detail: "Transfers native testnet MON from your wallet to \(token.lowercased). This cannot be reversed."))
                headline = "Send \(intent.value.formatted(decimals: 18, maxFractionDigits: 18)) MON"
                plain = "You are sending testnet MON to \(token.short). Transfers cannot be undone."
            }

        case .erc20Approve(let spender, let value):
            if value.isZero {
                findings.append(.init(code: .approvalRevoke, level: .informational, title: "Sets allowance to zero",
                                      detail: "Revokes \(spender.lowercased)'s allowance on \(tokenName)."))
                headline = "Revoke token allowance"
                plain = "This removes \(spender.short)'s permission to spend this token for you."
            } else if value == .max || value >= effectivelyUnlimited {
                findings.append(.init(code: .unlimitedApproval, level: .high, title: value == .max ? "Unlimited allowance (MAX uint256)" : "Effectively unlimited allowance (\(value.decimalString) base units)",
                                      detail: "Lets \(spender.lowercased) move any amount of \(tokenName) from your wallet, now or later, until you revoke it. Nothing moves when you sign this, but the permission stays open."))
                headline = "Unlimited token approval"
                plain = "\(spender.short) could take all of this token from your wallet at any time in the future, without asking again."
            } else {
                // Without verified decimals Mona Guard cannot tell how large the allowance is (or whether this is
                // an ERC-721 approve sharing the selector), so it is unverified rather than "limited".
                findings.append(.init(code: .boundedApproval, level: context.tokenDecimals == nil ? .unknown : .caution, title: "Allowance of \(amount(value))",
                                      detail: "Lets \(spender.lowercased) move up to \(amount(value)) of \(tokenName) from your wallet until it is used or revoked."))
                headline = "Limited token approval"
                plain = "\(spender.short) could spend up to this amount of the token from your wallet later."
            }

        case .erc20Transfer(let recipient, let value):
            findings.append(.init(code: .tokenTransfer, level: .caution, title: "Transfers \(amount(value))",
                                  detail: "Calls transfer on \(tokenName), sending to \(recipient.lowercased)."))
            headline = "Token transfer"
            plain = "This sends tokens from your wallet to \(recipient.short). It cannot be undone."

        case .erc20TransferFrom(let owner, let recipient, let value):
            let fromSelf = owner == intent.from
            findings.append(.init(code: .tokenTransferFrom, level: fromSelf ? .caution : .unknown, title: "transferFrom of \(amount(value))",
                                  detail: "Moves tokens from \(owner.lowercased) to \(recipient.lowercased) using an existing allowance."))
            headline = "Token transferFrom"
            plain = fromSelf ? "This moves your tokens to \(recipient.short)." : "This moves tokens owned by \(owner.short), not by you. Mona Guard cannot verify why."

        case .setApprovalForAll(let op, let approved):
            if approved {
                findings.append(.init(code: .operatorGrant, level: .high, title: "Grants operator over all items in this collection",
                                      detail: "Lets \(op.lowercased) transfer every token you hold in contract \(token.lowercased), including ones you acquire later, until revoked."))
                headline = "Blanket collection approval"
                plain = "\(op.short) could move every item you own in this collection, now and later."
            } else {
                findings.append(.init(code: .operatorRevoke, level: .informational, title: "Revokes operator",
                                      detail: "Removes \(op.lowercased)'s operator rights on \(token.lowercased)."))
                headline = "Revoke collection approval"
                plain = "This removes \(op.short)'s permission over this collection."
            }

        case .v2Swap(_, let amountIn, let amountOutMin, let path, let recipient, _):
            let input = amountIn.map { "\($0.decimalString) base units of \(path.first!.short)" } ?? "\(intent.value.formatted(decimals: 18, maxFractionDigits: 18)) MON"
            if recipient == intent.from {
                findings.append(.init(code: .swap, level: .caution, title: "Swap via a Uniswap V2-style router",
                                      detail: "Spends \(input) for at least \(amountOutMin.decimalString) base units of \(path.last!.short) (path of \(path.count) tokens), sent back to your wallet."))
            } else {
                findings.append(.init(code: .swapToOtherRecipient, level: .high, title: "Swap output goes to another address",
                                      detail: "The swapped tokens would be sent to \(recipient.lowercased), not to your wallet."))
            }
            if amountOutMin.isZero {
                findings.append(.init(code: .swap, level: .caution, title: "No minimum output (slippage unlimited)",
                                      detail: "amountOutMin is 0, so the swap accepts any price."))
            }
            findings.append(.init(code: .unverifiedRouter, level: .informational, title: "Router identity not verified",
                                  detail: "Mona Guard decoded this by function signature. It has not verified that \(token.lowercased) is a genuine Uniswap V2 router."))
            headline = recipient == intent.from ? "Token swap" : "Swap to another address"
            plain = recipient == intent.from ? "You are trading tokens through \(token.short). Check the amounts before continuing."
                : "This swap sends what you buy to someone else."

        case .wrapNative:
            findings.append(.init(code: .wrapNative, level: token == MonadNetwork.wmon ? .informational : .unknown,
                                  title: "deposit(): wrap \(intent.value.formatted(decimals: 18, maxFractionDigits: 18)) MON",
                                  detail: token == MonadNetwork.wmon ? "Converts MON into WMON at the canonical Wrapped MON contract." : "Calls deposit() on \(token.lowercased), which is not the canonical WMON contract."))
            headline = "Wrap MON"
            plain = token == MonadNetwork.wmon ? "This converts testnet MON into the same amount of WMON." : "This sends MON to a contract that is not the official WMON."

        case .unwrapNative(let amount):
            findings.append(.init(code: .unwrapNative, level: token == MonadNetwork.wmon ? .informational : .unknown,
                                  title: "withdraw(): unwrap \(amount.formatted(decimals: 18, maxFractionDigits: 18)) WMON",
                                  detail: token == MonadNetwork.wmon ? "Converts WMON back into MON at the canonical Wrapped MON contract." : "Calls withdraw() on \(token.lowercased), which is not the canonical WMON contract."))
            headline = "Unwrap WMON"
            plain = "This converts WMON back into testnet MON."

        case .unknown(let selector):
            findings.append(.init(code: .unknownSelector, level: .unknown, title: "Unrecognized function \(selector)",
                                  detail: "Mona Guard cannot decode this call, so it cannot tell you what it does. Treat it as unverified."))
            headline = "Unknown contract call"
            plain = "Mona Guard can't read this request. Only continue if you trust the site and expected this."

        case .malformed(let selector, let reason):
            findings.append(.init(code: .malformedCalldata, level: .unknown, title: "Malformed calldata for \(selector)",
                                  detail: reason))
            headline = "Malformed request"
            plain = "This request is not encoded the way its function expects. That is unusual and could be an attempt to hide what it does."
        }

        if !intent.value.isZero, decoded != .none, decoded != .wrapNative, !Self.isNativeInSwap(decoded) {
            findings.append(.init(code: .nativeValueWithCall, level: .caution, title: "Also sends \(intent.value.formatted(decimals: 18, maxFractionDigits: 18)) MON",
                                  detail: "Native value is attached to this contract call."))
        }

        if decoded != .none, context.targetHasCode == false {
            findings.append(.init(code: .recipientHasNoCode, level: .unknown, title: "Target has no contract code",
                                  detail: "\(token.lowercased) has no code on Monad Testnet, so this call will not do what it claims."))
        }

        if case .erc20Approve = decoded, context.tokenDecimals == nil {
            findings.append(.init(code: .tokenMetadataUnverified, level: .informational, title: "Token metadata unavailable",
                                  detail: "decimals()/symbol() could not be read on-chain; amounts are shown in base units."))
        }

        return finish(intent, headline: headline, plain: plain, findings: findings, decoded: decoded, context: context)
    }

    private static func isNativeInSwap(_ d: DecodedCall) -> Bool {
        if case .v2Swap(_, nil, _, _, _, _) = d { return true }
        return false
    }

    private static func assessDeployment(_ intent: TransactionIntent, context: OnchainContext) -> RiskAssessment {
        let findings = [Finding(code: .contractDeployment, level: .unknown, title: "Deploys a new contract (\(intent.data.count) bytes)",
                                detail: "Creates a contract from bytecode. Mona Guard cannot verify what the bytecode does.")]
        return finish(intent, headline: "Contract deployment", plain: "This creates a new smart contract from your wallet.",
                      findings: findings, decoded: .none, context: context)
    }

    private static func finish(_ intent: TransactionIntent, headline: String, plain: String, findings: [Finding], decoded: DecodedCall, context: OnchainContext) -> RiskAssessment {
        var findings = findings
        if context.simulationAttempted {
            if let err = context.simulationError {
                findings.append(.init(code: .simulationFailed, level: .unknown, title: "eth_estimateGas failed",
                                      detail: "The RPC reports this transaction would fail or could not be estimated: \(err)"))
            } else if let gas = context.gasEstimate {
                findings.append(.init(code: .simulationPassed, level: .informational, title: "eth_estimateGas: \(gas.decimalString) gas",
                                      detail: "The RPC estimated gas at the latest block. This is not a full simulation of effects."))
            }
        } else {
            // Fail closed: without on-chain checks the request is unverified.
            findings.append(.init(code: .simulationUnavailable, level: .unknown, title: "On-chain checks unavailable",
                                  detail: "Monad Testnet RPC could not be reached, so gas estimation and contract checks did not run."))
        }
        let level = findings.map(\.level).max() ?? .unknown
        return RiskAssessment(level: level, headline: headline, plainEnglish: plain, findings: findings,
                              decoded: decoded, fingerprint: intent.fingerprint)
    }
}
