# ComposeKit

The Docker Compose parsing & orchestration engine behind
[`container-compose`](https://github.com/flaticols/container-compose) — a
compatibility layer for [Apple's `container`](https://github.com/apple/container).

ComposeKit is CLI-agnostic (no ArgumentParser dependency). It parses a Compose
file, resolves the project, plans start order, translates services into stable
public `container` CLI invocations, and orchestrates `up`/`down`/`ps`/`logs`.
Frontends — the `container-compose` binary and the `container` CLI plugin — wire
it into a command surface.

## Modules

```
Sources/ComposeKit/
  Model/
    ComposeFile.swift   # typed compose-spec subset
    Scalars.swift       # polymorphic decoders (string|list|map)
  Project.swift         # locate + load + project-name resolution
  Planner.swift         # depends_on topological sort
  Translator.swift      # Service -> `container run/build` args   ← core mapping
  ContainerRunner.swift # subprocess wrapper around `container`
  Orchestrator.swift    # up / down / ps / logs
  Interpolation.swift   # ${VAR} / .env expansion
  HealthChecker.swift   # healthcheck polling + service_healthy gating
```

## Use as a dependency

```swift
.package(url: "https://github.com/flaticols/ComposeKit.git", from: "0.1.0"),
```

```swift
.target(
    name: "YourTool",
    dependencies: [.product(name: "ComposeKit", package: "ComposeKit")]
)
```

## Build & test

```sh
swift build
swift test
```

## License

Apache-2.0 (matches the upstream `container` project).
