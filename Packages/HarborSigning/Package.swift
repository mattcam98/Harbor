// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarborSigning",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HarborSigning", targets: ["HarborSigning"]),
    ],
    dependencies: [
        .package(path: "../HarborCore"),
        // Apple ID authentication, developer portal and code signing.
        // Pinned by the submodule commit; its own branch-tracked dependencies
        // are held by Package.resolved, which CI enforces.
        .package(path: "../../Vendor/SideSign"),
    ],
    targets: [
        .target(
            name: "HarborSigning",
            dependencies: [
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
