# ``ComposeKitContainer``

Map a parsed Compose project onto Apple's `container` CLI and orchestrate it.

## Overview

`ComposeKitContainer` is the runtime layer on top of `ComposeKit`. It turns the
runtime-agnostic model into `container run` / `container build` invocations and
runs them, handling the side effects the core deliberately avoids: provisioning
networks and volumes, materializing configs and secrets, gating `depends_on`
conditions, and recreating containers.

```swift
import ComposeKit
import ComposeKitContainer

let project = try Project.load(
    explicit: nil, projectName: nil,
    cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

let orchestrator = Orchestrator(project: project, runner: ContainerRunner())
try orchestrator.up(build: false, only: [])
```

`ContainerTranslator` is a pure function from a service to an argument vector, so
it is easy to test in isolation; `Orchestrator` owns the process execution and
filesystem effects via `ContainerRunner`.

## Topics

### Orchestration

- ``Orchestrator``
- ``ContainerRunner``

### Translation

- ``ContainerTranslator``
- ``HealthChecker``
