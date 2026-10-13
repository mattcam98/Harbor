// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarborPlatform",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HarborPlatform", targets: ["HarborPlatform"]),
    ],
    dependencies: [
        .package(path: "../HarborCore"),
    ],
    targets: [
        // Apple-framework implementations of HarborCore's protocols. Tests that
        // need a signed host (keychain) live in the app's test bundle.
        .target(name: "HarborPlatform", dependencies: ["HarborCore"]),
        .testTarget(name: "HarborPlatformTests", dependencies: ["HarborPlatform", "HarborCore"]),
    ],
    swiftLanguageModes: [.v6]
)
