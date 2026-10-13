import Foundation

/// Origins of the pages bundled inside the MonaSurf app. In the app they are served from a custom URL scheme, so
/// no website on the internet can claim them. Training-demo labels are keyed on these native constants only.
enum DemoOrigins {
    static let demoOrigin = "shield-demo://dapp"
    /// NebulaDrop: the fictional deceptive airdrop page used for the scam-protection demo.
    static let nebulaOrigin = "shield-demo://nebuladrop"
    static let bundledOrigins: Set<String> = [demoOrigin, nebulaOrigin]
}
