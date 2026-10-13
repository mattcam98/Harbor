// swift-tools-version: 6.0
import PackageDescription

// Everything the app links, as one package. Its Package.resolved is the
// app's dependency lockfile: the Xcode project is generated and has none of
// its own, so the build copies this one in and refuses to resolve anything
// else (see scripts/generate-project.sh).
let package = Package(
    name: "HarborKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HarborKit", targets: ["HarborKit"]),
    ],
    dependencies: [
        .package(path: "../HarborCore"),
        .package(path: "../HarborPlatform"),
        .package(path: "../HarborSigning"),
        .package(path: "../HarborDevice"),
    ],
    targets: [
        .target(
            name: "HarborKit",
            dependencies: ["HarborCore", "HarborPlatform", "HarborSigning", "HarborDevice"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
