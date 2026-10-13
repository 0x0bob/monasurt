// swift-tools-version: 5.9
// Mona Guard: the deterministic security engine extracted from the MonaSurf iOS browser.
// Platform-independent Swift (Foundation + CryptoKit). Build and test with `swift build` / `swift test`.
import PackageDescription

let package = Package(
    name: "MonaGuard",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MonaGuard", targets: ["MonaGuard"]),
        .executable(name: "nebuladrop-check", targets: ["nebuladrop-check"]),
    ],
    targets: [
        .target(name: "MonaGuard", path: "Sources/MonaGuard"),
        .executableTarget(name: "nebuladrop-check", dependencies: ["MonaGuard"], path: "Sources/nebuladrop-check"),
        .testTarget(name: "MonaGuardTests", dependencies: ["MonaGuard"], path: "Tests/MonaGuardTests"),
    ]
)
