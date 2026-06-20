# ComposeKit

The Docker Compose parsing & orchestration engine behind
[`container-compose`](https://github.com/flaticols/container-compose) — a
compatibility layer for [Apple's `container`](https://github.com/apple/container).

ComposeKit is CLI-agnostic (no ArgumentParser dependency). It is split into two
layers: a **runtime-agnostic spec core** and a **`container` runtime layer**.
Frontends — the `container-compose` binary and the `container` CLI plugin — wire
the container layer into a command surface.

## Documentation

API reference is generated with [Swift-DocC](https://www.swift.org/documentation/docc/)
and published to GitHub Pages: <https://flaticols.github.io/ComposeKit/>.

Build it locally:

```sh
swift package --disable-sandbox preview-documentation --target ComposeKit
```

(Publishing requires Pages set to "GitHub Actions" once under Settings -> Pages.)

## Modules

```
Sources/ComposeKit/              # core — depends only on Yams
  Model/
    ComposeFile.swift   # typed compose-spec subset (popular local-dev fields)
    Scalars.swift       # polymorphic decoders (string|list|map, ulimits, …)
  Project.swift         # locate + load + name + profile resolution
  Profiles.swift        # profile activation (which services are enabled)
  Planner.swift         # depends_on topological sort
  Interpolation.swift   # ${VAR} / .env expansion

Sources/ComposeKitContainer/     # runtime — depends on ComposeKit
  ContainerTranslator.swift # Service -> `container run/build` args  ← core mapping
  ContainerRunner.swift     # subprocess wrapper around `container`
  Orchestrator.swift        # up / down / ps / logs
  HealthChecker.swift       # healthcheck polling + service_healthy gating

Sources/compose-validate/        # tiny CLI: parse / --plan a file (no deps)
```

The core knows nothing about `container`; anyone wanting just to parse the spec
can depend on `ComposeKit` alone. The container-specific compatibility decisions
live in `ComposeKitContainer` and are shared by every frontend.

## Use as a dependency

```swift
.package(url: "https://github.com/flaticols/ComposeKit.git", from: "0.1.0"),
```

```swift
.target(
    name: "YourTool",
    dependencies: [
        // Spec parsing only:
        .product(name: "ComposeKit", package: "ComposeKit"),
        // …plus the container mapping/orchestration:
        .product(name: "ComposeKitContainer", package: "ComposeKit"),
    ]
)
```

## Profiles

Services with a `profiles:` key are started only when one of their profiles is
active — via `--profile` (frontends) or `COMPOSE_PROFILES`. Unprofiled services
always run; dependencies of an enabled service are pulled in regardless.

```swift
let project = try Project.load(explicit: nil, projectName: nil, cwd: cwd,
                               profiles: ["tools"])
let enabled = project.enabledServices()   // honors profiles + depends_on
```

## Dependency conditions

`depends_on` conditions are honored during `up`:

- `service_started` — ordering only (topological).
- `service_healthy` — gated by polling the dependency's `healthcheck`.
- `service_completed_successfully` — the dependency is run **attached** (to
  completion); a non-zero exit aborts `up`. Ideal for one-shot migration/seed
  steps that must finish before dependents start.

## Configs & secrets

Top-level `configs:` / `secrets:` referenced by a service are provisioned as
**read-only file bind mounts** — secrets at `/run/secrets/<name>`, configs at
`/<name>` (or an explicit `target:`). `file:` sources mount directly;
`content:`/`environment:` sources are materialized to a temp file. `external:`
sources and `uid`/`gid`/`mode` are warned (not enforced — bind mounts can't
express them). Single-file bind support depends on the `container` runtime.

## Composition: extends & include

`Project.load` flattens composition before the model is used:

- **`include:`** merges other Compose files into the project (the including file
  wins on overlap); nested includes are resolved depth-first.
- **`extends:`** inherits another service's config, from the same file or another
  (`{service, file}`); cycles are detected.

Merge rules (override wins): scalars/objects replace, maps (`environment`,
`labels`, `sysctls`) merge by key, sequences (`ports`, `volumes`, ...)
concatenate, and `depends_on` is unioned. This is pragmatic and Compose-flavored
rather than a full implementation of every field-specific rule.

## Build

`build` long-form fields `no_cache`, `labels`, and `secrets` translate to
`container build` flags (`--no-cache`, `--label`, `--secret`). `ssh`, `network`,
and `cache_from` are decoded but warned (no `container build` equivalent).

## compose-validate

A dependency-free tool to check a file parses and inspect the planned argv:

```sh
swift run compose-validate compose.yaml                 # does it parse?
swift run compose-validate --plan compose.yaml          # show `container` argv
swift run compose-validate --profile tools compose.yaml # with a profile active
```

## Build & test

```sh
swift build
swift test
```

## Interop testing

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) validates parsing &
translation fidelity — Apple's `container` is macOS/Virtualization-only and
cannot run in CI, so the workflow proves *we parse what the spec and docker
parse and emit the argv we intend*, not that containers boot:

- **swift build/test** on macOS (incl. a test that parses every file in
  `Tests/.../Fixtures/corpus`).
- **Schema validation** — every fixture is checked against the official
  compose-spec JSON Schema, vendored under [`Schema/`](Schema/).
- **docker parity** — `Scripts/parity.sh` asserts `docker compose config` and
  `compose-validate` both accept each corpus file.

A second scheduled workflow
([`nightly-schema.yml`](.github/workflows/nightly-schema.yml)) refreshes the
vendored schema from upstream each night, re-validates the fixtures and runs the
tests, and opens a PR when the spec changed — so spec drift surfaces early.

## License

Apache-2.0 (matches the upstream `container` project).
