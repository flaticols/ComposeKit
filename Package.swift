// swift-tools-version: 6.0
//===----------------------------------------------------------------------===//
// ComposeKit — Docker Compose parsing & orchestration engine.
//
// Two layers:
//   • ComposeKit          — runtime-agnostic spec core: parse a Compose file,
//                           interpolate variables, resolve the project, filter
//                           by profiles, plan start order. Depends only on Yams.
//   • ComposeKitContainer — maps the parsed model onto Apple's `container` CLI
//                           and orchestrates up/down/ps/logs. This is where the
//                           container-specific compatibility decisions live and
//                           is shared by every frontend (the container-compose
//                           binary and the `container` plugin).
//
// No CLI/ArgumentParser dependency — frontends wire the layers into a command
// surface. `compose-validate` is a tiny built-in tool used by CI and humans to
// parse/plan a file without a full frontend.
//===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
    name: "ComposeKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ComposeKit", targets: ["ComposeKit"]),
        .library(name: "ComposeKitContainer", targets: ["ComposeKitContainer"]),
        .executable(name: "compose-validate", targets: ["compose-validate"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0"),
    ],
    targets: [
        // Runtime-agnostic Compose spec core.
        .target(
            name: "ComposeKit",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/ComposeKit"
        ),
        // Apple `container` runtime layer.
        .target(
            name: "ComposeKitContainer",
            dependencies: ["ComposeKit"],
            path: "Sources/ComposeKitContainer"
        ),
        // Parse/plan a Compose file from the command line (used by CI parity).
        .executableTarget(
            name: "compose-validate",
            dependencies: ["ComposeKit", "ComposeKitContainer"],
            path: "Sources/compose-validate"
        ),
        .testTarget(
            name: "ComposeKitTests",
            dependencies: ["ComposeKit", "ComposeKitContainer"],
            path: "Tests/ComposeKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
