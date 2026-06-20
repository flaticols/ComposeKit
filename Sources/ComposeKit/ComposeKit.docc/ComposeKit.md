# ``ComposeKit``

Parse Docker Compose files into a typed model, interpolate variables, resolve
the project, filter by profiles, and plan start order.

## Overview

ComposeKit is the runtime-agnostic core of the Compose engine behind
`container-compose`. It depends only on Yams and knows nothing about any
container runtime, so it can be used on its own to read and reason about Compose
files. The runtime mapping onto Apple's `container` CLI lives in the companion
`ComposeKitContainer` module.

A typical flow loads a project and plans its start order:

```swift
import ComposeKit

let project = try Project.load(
    explicit: nil, projectName: nil,
    cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    profiles: ["tools"])

let enabled = project.enabledServices()
let order = try Planner.startOrder(project.file.services)
    .filter { enabled.contains($0) }
```

## Topics

### Loading a project

- ``Project``
- ``ComposeError``

### The Compose model

- ``ComposeFile``
- ``Service``

### Planning and profiles

- ``Planner``
- ``Profiles``

### Variables and environment

- ``Interpolator``
- ``EnvFile``
