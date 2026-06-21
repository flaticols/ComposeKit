# ComposeKit

A runtime-agnostic Docker Compose parsing engine in Swift. It is the spec core
behind [`container-compose`](https://github.com/flaticols/container-compose) (a
compatibility layer for [Apple's `container`](https://github.com/apple/container)),
but it depends only on Yams and knows nothing about any container runtime — so it
is usable on its own to read and reason about Compose files.

> [!WARNING]
> ComposeKit is in early development (pre-1.0). The API and behavior may change
> between releases, and not every Compose feature is supported yet. Not
> recommended for production use.

ComposeKit parses a Compose file, interpolates `${VAR}` references, merges
`.env` with the environment, flattens `include:` and `extends:`, filters
services by profiles, and plans start order from `depends_on`. Mapping the
parsed model onto a specific container runtime lives in the consuming frontend.

## Documentation

API reference is generated with [Swift-DocC](https://www.swift.org/documentation/docc/)
and published to GitHub Pages: <https://flaticols.github.io/ComposeKit/>.

Build it locally:

```sh
swift package --disable-sandbox preview-documentation --target ComposeKit
```

(The Docs workflow enables Pages automatically on first run.)

## Modules

```
Sources/ComposeKit/
  Model/
    ComposeFile.swift   # typed compose-spec subset
    Scalars.swift       # polymorphic decoders (string|list|map, ulimits, …)
  Project.swift         # locate + load + name + profile resolution
  Profiles.swift        # profile activation (which services are enabled)
  Planner.swift         # depends_on topological sort
  Interpolation.swift   # ${VAR} / .env expansion
  Composition.swift     # flatten include: + extends:
  Merge.swift           # deep-merge rules for extends/include

Sources/compose-validate/    # tiny CLI: does ComposeKit parse a file? (no deps)
Sources/compose-bench/       # lightweight micro-benchmarks
```

## Use as a dependency

```swift
.package(url: "https://github.com/flaticols/ComposeKit.git", from: "0.0.2"),
```

```swift
.target(
    name: "YourTool",
    dependencies: [.product(name: "ComposeKit", package: "ComposeKit")]
)
```

```swift
import ComposeKit

let project = try Project.load(
    explicit: nil, projectName: nil,
    cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    profiles: ["tools"])

let enabled = project.enabledServices()                       // honors profiles + depends_on
let order = try Planner.startOrder(project.file.services)     // dependency order
    .filter { enabled.contains($0) }
```

## Profiles

Services with a `profiles:` key are enabled only when one of their profiles is
active — via the `profiles:` argument to `Project.load` or `COMPOSE_PROFILES`.
Unprofiled services always run; dependencies of an enabled service are pulled in
regardless. `Project.enabledServices(explicit:)` resolves the set.

## Composition: extends & include

`Project.load` flattens composition before the model is used:

- **`include:`** merges other Compose files into the project (the including file
  wins on overlap); nested includes are resolved depth-first.
- **`extends:`** inherits another service's config, from the same file or another
  (`{service, file}`); cycles are detected.

Merge rules (override wins): scalars/objects replace, maps (`environment`,
`labels`, `sysctls`) merge by key, sequences (`ports`, `volumes`, …) concatenate,
and `depends_on` is unioned. Pragmatic and Compose-flavored rather than a full
implementation of every field-specific rule.

## compose-validate

A small CLI to check that a file parses:

```sh
swift run compose-validate compose.yaml                 # does it parse?
swift run compose-validate --profile tools compose.yaml # report profile-active services
```

## Build & test

```sh
swift build
swift test
```

Lightweight, dependency-free micro-benchmarks (parse / interpolate):

```sh
swift run -c release compose-bench
```

## Interop testing

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) validates parsing
fidelity against external sources of truth:

- **swift build/test** on macOS (incl. a test that parses every file in
  `Tests/.../Fixtures/corpus`).
- **Schema validation** — every fixture is checked against the official
  compose-spec JSON Schema, vendored under [`Schema/`](Schema/).
- **docker parity** — `Scripts/parity.sh` asserts `docker compose config` and
  `compose-validate` both accept each corpus file.

A scheduled workflow ([`nightly-schema.yml`](.github/workflows/nightly-schema.yml))
refreshes the vendored schema from upstream each night, re-validates the fixtures
and runs the tests, and opens a PR when the spec changed — so spec drift surfaces
early.

## License

Apache-2.0 (matches the upstream `container` project).
