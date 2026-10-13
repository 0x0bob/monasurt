import Foundation
@testable import MonaGuard

enum Fixture {
    static let account = Address("0x1111111111111111111111111111111111111111")!
    static let token = Address("0x2222222222222222222222222222222222222222")!
    static let spender = Address("0x3333333333333333333333333333333333333333")!
    static let origin = "shield-demo://dapp"

    static func calldata(_ selector: String, _ words: [Data]) -> Data {
        CalldataDecoder.encode(selector: selector, words: words)
    }

    static func approve(_ amount: UInt256, spender: Address = spender) -> Data {
        calldata(Selector.approve, [CalldataDecoder.word(spender), CalldataDecoder.word(amount)])
    }

    static func intent(to: Address = token, value: UInt256 = .zero, data: Data = Data(), gas: UInt256? = nil) -> TransactionIntent {
        TransactionIntent(requestId: "1", origin: origin, chainId: 10143, from: account, to: to, value: value, data: data, gasLimit: gas)
    }

    static let liveContext = OnchainContext(targetHasCode: true, tokenSymbol: "DEMO", tokenDecimals: 18, gasEstimate: UInt256(46_000), simulationError: nil, simulationAttempted: true)
}
