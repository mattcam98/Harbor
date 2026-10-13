// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarborCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HarborCore", targets: ["HarborCore"]),
    ],
    dependencies: [
        // On Apple platforms this is a thin shim over CryptoKit.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.9.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "HarborCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(
            name: "HarborCoreTests",
            dependencies: [
                "HarborCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
