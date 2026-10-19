// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarborSigning",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HarborSigning", targets: ["HarborSigning"]),
        // The Mac half of Harbor Setup: signs in and signs Harbor.
        .executable(name: "harbor-setup-mac", targets: ["HarborSetupMac"]),
    ],
    dependencies: [
        .package(path: "../HarborCore"),
        // Apple ID authentication, developer portal and code signing.
        // Pinned by the submodule commit; its own branch-tracked dependencies
        // are held by Package.resolved, which CI enforces.
        .package(path: "../../Vendor/SideSign"),
        // The signer underneath SideSign, used directly to sign guest apps.
        // Same requirement as SideSign's own, so the lockfile pins one revision.
        .package(url: "https://github.com/mahee96/CodeSignKit.git", branch: "main"),
        // SideSign's anisette layer, used directly to describe the device an
        // anisette server stands in for. Same requirement as SideSign's own.
        .package(url: "https://github.com/mahee96/AnisetteKit.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "HarborSigning",
            dependencies: [
                "HarborCore",
                .product(name: "SideSign", package: "SideSign"),
                .product(name: "CodeSignKit", package: "CodeSignKit"),
                .product(name: "AnisetteKit", package: "AnisetteKit"),
            ]
        ),
        .executableTarget(
            name: "HarborSetupMac",
            dependencies: [
                "HarborSigning",
                "HarborCore",
                .product(name: "SideSign", package: "SideSign"),
            ]
        ),
        .testTarget(
            name: "HarborSigningTests",
            dependencies: [
                "HarborSigning",
                "HarborCore",
                .product(name: "SideSign", package: "SideSign"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
