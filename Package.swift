// swift-tools-version: 6.0
//===----------------------------------------------------------------------===//
// ComposeKit — Docker Compose parsing & orchestration engine.
//
// The reusable core extracted from container-compose: it parses a Compose file,
// plans start order, translates services into `container` CLI invocations, and
// orchestrates up/down/ps/logs. No CLI/ArgumentParser dependency — consumers
// (the container-compose binary, the `container` plugin) wire it into a frontend.
//===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
    name: "ComposeKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ComposeKit", targets: ["ComposeKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0")
    ],
    targets: [
        .target(
            name: "ComposeKit",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/ComposeKit"
        ),
        .testTarget(
            name: "ComposeKitTests",
            dependencies: ["ComposeKit"],
            path: "Tests/ComposeKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
