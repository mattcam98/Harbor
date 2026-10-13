// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarborDevice",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HarborDevice", targets: ["HarborDevice"]),
    ],
    dependencies: [
        .package(path: "../HarborCore"),
        // Lockdown / RemotePairing transport: install, profiles, debugging.
        // Pinned by the submodule commit; its prebuilt frameworks are pinned
        // by checksum in its manifest, and the branch-tracked dependency by
        // Package.resolved.
        .package(path: "../../Vendor/minimuxer"),
        .package(path: "../../Vendor/minimuxer/Common"),
    ],
    targets: [
        .target(
            name: "HarborDevice",
            dependencies: [
                "HarborCore",
                .product(name: "Minimuxer", package: "minimuxer"),
                .product(name: "MinimuxerCommon", package: "Common"),
            ]
        ),
        .testTarget(
            name: "HarborDeviceTests",
            dependencies: [
                "HarborDevice",
                "HarborCore",
                .product(name: "Minimuxer", package: "minimuxer"),
                .product(name: "MinimuxerCommon", package: "Common"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
