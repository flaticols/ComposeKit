// swift-tools-version: 6.0
// ComposeKit — a runtime-agnostic Docker Compose parsing engine.
//
// Parses a Compose file, interpolates variables, resolves the project, flattens
// include:/extends:, filters by profiles, and plans start order. Depends only on
// Yams. The mapping onto a specific container runtime (e.g. Apple's `container`)
// lives in the consuming frontend, not here.
//
// `compose-validate` is a tiny built-in tool (used by CI and humans) to check a
// file parses; `compose-bench` holds lightweight micro-benchmarks.

import PackageDescription

let package = Package(
    name: "ComposeKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ComposeKit", targets: ["ComposeKit"]),
        .executable(name: "compose-validate", targets: ["compose-validate"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "ComposeKit",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/ComposeKit"
        ),
        // Check a Compose file parses (used by CI parity).
        .executableTarget(
            name: "compose-validate",
            dependencies: ["ComposeKit"],
            path: "Sources/compose-validate"
        ),
        // Lightweight micro-benchmarks: `swift run -c release compose-bench`.
        .executableTarget(
            name: "compose-bench",
            dependencies: ["ComposeKit"],
            path: "Sources/compose-bench"
        ),
        .testTarget(
            name: "ComposeKitTests",
            dependencies: ["ComposeKit"],
            path: "Tests/ComposeKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
