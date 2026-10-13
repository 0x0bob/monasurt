import Foundation

/// Decodes the handful of selectors Mona Guard understands with strict ABI checks. Anything else is `.unknown`;
/// anything that matches a known selector but is not canonically encoded is `.malformed`.
enum DecodedCall: Equatable, Sendable {
    case none
    case erc20Approve(spender: Address, amount: UInt256)
    case erc20Transfer(recipient: Address, amount: UInt256)
    case erc20TransferFrom(owner: Address, recipient: Address, amount: UInt256)
    case setApprovalForAll(operator: Address, approved: Bool)
    /// Uniswap V2-style router swap. `amountIn` is nil when the input is the native value (ETH/MON variants).
    case v2Swap(function: String, amountIn: UInt256?, amountOutMin: UInt256, path: [Address], recipient: Address, deadline: UInt256)
    case wrapNative
    case unwrapNative(amount: UInt256)
    case unknown(selector: String)
    case malformed(selector: String, reason: String)

    var functionSignature: String? {
        switch self {
        case .erc20Approve: return "approve(address,uint256)"
        case .erc20Transfer: return "transfer(address,uint256)"
        case .erc20TransferFrom: return "transferFrom(address,address,uint256)"
        case .setApprovalForAll: return "setApprovalForAll(address,bool)"
        case .v2Swap(let f, _, _, _, _, _): return f
        case .wrapNative: return "deposit()"
        case .unwrapNative: return "withdraw(uint256)"
        default: return nil
        }
    }
}

enum Selector {
    static let approve = "0x095ea7b3"
    static let transfer = "0xa9059cbb"
    static let transferFrom = "0x23b872dd"
    static let setApprovalForAll = "0xa22cb465"
    static let symbol = "0x95d89b41"
    static let decimals = "0x313ce567"
    static let allowance = "0xdd62ed3e"
    static let deposit = "0xd0e30db0"
    static let withdraw = "0x2e1a7d4d"
    /// Uniswap V2 router swaps: selector -> (signature, has amountIn word).
    static let v2Swaps: [String: (String, Bool)] = [
        "0x38ed1739": ("swapExactTokensForTokens(uint256,uint256,address[],address,uint256)", true),
        "0x18cbafe5": ("swapExactTokensForETH(uint256,uint256,address[],address,uint256)", true),
        "0x7ff36ab5": ("swapExactETHForTokens(uint256,address[],address,uint256)", false),
        "0x5c11d795": ("swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)", true),
        "0x791ac947": ("swapExactTokensForETHSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)", true),
        "0xb6f9de95": ("swapExactETHForTokensSupportingFeeOnTransferTokens(uint256,address[],address,uint256)", false),
    ]
}

enum CalldataDecoder {
    static func decode(_ data: Data) -> DecodedCall {
        if data.isEmpty { return .none }
        guard data.count >= 4 else { return .malformed(selector: Hex.encode(data), reason: "Calldata shorter than a 4-byte selector") }
        let bytes = Data(data)
        let selector = Hex.encode(bytes.prefix(4))
        let args = bytes.dropFirst(4)

        func words(_ n: Int) -> [Data]? {
            guard args.count == n * 32 else { return nil }
            return (0..<n).map { i in Data(args[args.startIndex + i * 32 ..< args.startIndex + (i + 1) * 32]) }
        }
        func address(_ w: Data) -> Address? {
            guard w.prefix(12).allSatisfy({ $0 == 0 }) else { return nil }
            return Address(word: Data(w.suffix(20)))
        }
        func lengthError(_ n: Int) -> DecodedCall {
            .malformed(selector: selector, reason: "Expected \(n * 32) argument bytes, found \(args.count)")
        }

        switch selector {
        case Selector.approve:
            guard let w = words(2) else { return lengthError(2) }
            guard let spender = address(w[0]) else { return .malformed(selector: selector, reason: "Spender is not a valid address word") }
            return .erc20Approve(spender: spender, amount: UInt256(bigEndian: w[1])!)
        case Selector.transfer:
            guard let w = words(2) else { return lengthError(2) }
            guard let to = address(w[0]) else { return .malformed(selector: selector, reason: "Recipient is not a valid address word") }
            return .erc20Transfer(recipient: to, amount: UInt256(bigEndian: w[1])!)
        case Selector.transferFrom:
            guard let w = words(3) else { return lengthError(3) }
            guard let owner = address(w[0]), let to = address(w[1]) else { return .malformed(selector: selector, reason: "Address argument is not a valid address word") }
            return .erc20TransferFrom(owner: owner, recipient: to, amount: UInt256(bigEndian: w[2])!)
        case Selector.setApprovalForAll:
            guard let w = words(2) else { return lengthError(2) }
            guard let op = address(w[0]) else { return .malformed(selector: selector, reason: "Operator is not a valid address word") }
            guard let flag = UInt256(bigEndian: w[1]), flag <= UInt256(1) else {
                return .malformed(selector: selector, reason: "Boolean argument is neither 0 nor 1")
            }
            return .setApprovalForAll(operator: op, approved: flag == UInt256(1))
        case Selector.deposit:
            return args.isEmpty ? .wrapNative : lengthError(0)
        case Selector.withdraw:
            guard let w = words(1) else { return lengthError(1) }
            return .unwrapNative(amount: UInt256(bigEndian: w[0])!)
        default:
            if let (signature, hasAmountIn) = Selector.v2Swaps[selector] {
                return decodeV2Swap(selector: selector, signature: signature, hasAmountIn: hasAmountIn, args: Data(args), address: address)
            }
            return .unknown(selector: selector)
        }
    }

    /// Strict canonical layout: head words, then `address[] path` (2...5 hops) as the only dynamic tail.
    private static func decodeV2Swap(selector: String, signature: String, hasAmountIn: Bool, args: Data, address: (Data) -> Address?) -> DecodedCall {
        let head = hasAmountIn ? 5 : 4
        func word(_ i: Int) -> Data? {
            guard args.count >= (i + 1) * 32 else { return nil }
            return Data(args[args.startIndex + i * 32 ..< args.startIndex + (i + 1) * 32])
        }
        guard args.count >= (head + 1) * 32, args.count % 32 == 0 else {
            return .malformed(selector: selector, reason: "Swap arguments are truncated")
        }
        let base = hasAmountIn ? 1 : 0
        guard let offset = word(base + 1).flatMap({ UInt256(bigEndian: $0) }), offset == UInt256(UInt64(head * 32)),
              let lenWord = word(head), let len = UInt256(bigEndian: lenWord), len >= UInt256(2), len <= UInt256(5) else {
            return .malformed(selector: selector, reason: "Swap path is not canonically encoded (2–5 hops)")
        }
        let n = Int(len.limbs[0])
        guard args.count == (head + 1 + n) * 32 else { return .malformed(selector: selector, reason: "Unexpected swap calldata length") }
        var path: [Address] = []
        for i in 0..<n {
            guard let a = word(head + 1 + i).flatMap(address) else { return .malformed(selector: selector, reason: "Swap path contains an invalid address") }
            path.append(a)
        }
        guard let to = word(base + 2).flatMap(address) else { return .malformed(selector: selector, reason: "Swap recipient is not a valid address") }
        let amountIn = hasAmountIn ? UInt256(bigEndian: word(0)!)! : nil
        return .v2Swap(function: signature, amountIn: amountIn, amountOutMin: UInt256(bigEndian: word(base)!)!,
                       path: path, recipient: to, deadline: UInt256(bigEndian: word(base + 3)!)!)
    }

    // MARK: Encoding helpers (used by the token metadata lookups and tests)

    static func encode(selector: String, words: [Data]) -> Data {
        var out = Hex.decode(selector)!
        for w in words { out.append(Data(repeating: 0, count: 32 - w.count) + w) }
        return out
    }

    static func word(_ address: Address) -> Data { Hex.decode(address.lowercased)! }
    static func word(_ value: UInt256) -> Data { value.bigEndianBytes }

    /// Decodes an ABI `string` return value; nil if not canonically encoded.
    static func decodeStringReturn(_ data: Data) -> String? {
        guard data.count >= 64, let offset = UInt256(bigEndian: data.prefix(32)), offset == UInt256(32),
              let len = UInt256(bigEndian: Data(data[data.startIndex + 32 ..< data.startIndex + 64])),
              len < UInt256(256) else { return nil }
        let n = Int(len.limbs[0])
        guard data.count >= 64 + n else { return nil }
        return String(data: Data(data[data.startIndex + 64 ..< data.startIndex + 64 + n]), encoding: .utf8)
    }
}
