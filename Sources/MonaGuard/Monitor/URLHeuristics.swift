import Foundation

/// Fast, local URL checks. Heuristics only: they can raise caution or risk, never prove a site is safe.
enum URLHeuristics {
    struct Finding: Equatable, Hashable, Sendable {
        enum Code: String, Sendable { case credentialsInURL, ipLiteralHost, punycode, lookalike, brandInOtherDomain, deepSubdomains, lureKeyword, longHost }
        let code: Code
        let level: RiskLevel
        let detail: String
    }

    /// Domains users are likely to be phished with on Monad Testnet. Exact matches (and their subdomains) are fine.
    static let protectedDomains = ["puddleswap.org", "monad.xyz", "monadscan.com", "monadvision.com", "perpl.xyz",
                                   "uniswap.org", "metamask.io", "opensea.io", "trustwallet.com", "privy.io"]
    static let lureWords = ["airdrop", "claim", "giveaway", "free-mint", "freemint", "connect-wallet", "walletconnect",
                            "verify-wallet", "wallet-verify", "restore-wallet", "seed", "recovery-phrase", "drainer"]

    /// Last two labels. MonaSurf has no Public Suffix List, so "a.co.uk" style suffixes are approximated (documented limitation).
    static func registrableDomain(_ host: String) -> String {
        let labels = host.split(separator: ".")
        return labels.suffix(2).joined(separator: ".")
    }

    static func analyze(_ url: URL) -> [Finding] {
        guard let rawHost = url.host?.lowercased(), !rawHost.isEmpty else { return [] }
        var out: [Finding] = []
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        if url.user != nil || url.password != nil || url.absoluteString.contains("@") && (url.absoluteString.split(separator: "/").dropFirst(2).first?.contains("@") ?? false) {
            out.append(.init(code: .credentialsInURL, level: .high, detail: "The address contains an '@' before the host, a trick used to disguise the real destination (\(host))."))
        }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) || host.contains(":") {
            out.append(.init(code: .ipLiteralHost, level: .caution, detail: "The site is addressed by a raw IP address instead of a domain name."))
        }
        if host.split(separator: ".").contains(where: { $0.hasPrefix("xn--") }) {
            out.append(.init(code: .punycode, level: .caution, detail: "The domain uses internationalized characters (punycode), which can imitate familiar names."))
        }
        let reg = registrableDomain(host)
        let isProtected = protectedDomains.contains(reg)
        if !isProtected {
            for p in protectedDomains {
                let brand = String(p.split(separator: ".")[0])
                let regName = String(reg.split(separator: ".").first ?? "")
                if host.contains(brand) && brand.count >= 5 {
                    out.append(.init(code: .brandInOtherDomain, level: .high,
                                     detail: "\"\(brand)\" appears in this address, but the site is \(reg), not \(p). This is a common phishing pattern."))
                    break
                }
                let d = levenshtein(regName, brand)
                if d > 0 && d <= (brand.count >= 8 ? 2 : 1) && regName.count >= 4 {
                    out.append(.init(code: .lookalike, level: .high, detail: "\(reg) looks very similar to \(p). Check the spelling carefully."))
                    break
                }
            }
        }
        if host.split(separator: ".").count > 4 {
            out.append(.init(code: .deepSubdomains, level: .caution, detail: "Unusually many subdomain levels (\(host))."))
        }
        let path = (host + url.path).lowercased()
        if !isProtected, let w = lureWords.first(where: { path.contains($0) }) {
            out.append(.init(code: .lureKeyword, level: .caution, detail: "The address contains \"\(w)\", a word often used to lure wallet owners."))
        }
        if host.count > 60 {
            out.append(.init(code: .longHost, level: .caution, detail: "Very long host name."))
        }
        return out
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
