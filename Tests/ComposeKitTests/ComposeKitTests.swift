import Foundation
import Testing

@testable import ComposeKit

private func loadFixture() throws -> Project {
    let url = Bundle.module.url(forResource: "compose", withExtension: "yaml", subdirectory: "Fixtures")!
    let dir = url.deletingLastPathComponent()
    return try Project.load(explicit: url.path, projectName: nil, cwd: dir)
}

@Suite("Compose parsing")
struct ParsingTests {
    @Test("project name comes from top-level name:")
    func projectName() throws {
        let project = try loadFixture()
        #expect(project.name == "demo")
    }

    @Test("all services parse")
    func services() throws {
        let project = try loadFixture()
        #expect(Set(project.file.services.keys) == ["db", "cache", "web"])
    }

    @Test("polymorphic environment: map and list forms")
    func environment() throws {
        let project = try loadFixture()
        let db = project.file.services["db"]!
        #expect(db.environment?.pairs().contains("POSTGRES_USER=app") == true)
        let web = project.file.services["web"]!
        #expect(web.environment?.pairs().contains("DATABASE_URL=postgres://app@db:5432/app") == true)
    }

    @Test("depends_on map form yields names")
    func dependsOn() throws {
        let project = try loadFixture()
        let web = project.file.services["web"]!
        #expect(Set(web.depends_on?.names ?? []) == ["db", "cache"])
    }

    @Test("build long form")
    func build() throws {
        let project = try loadFixture()
        let web = project.file.services["web"]!
        #expect(web.build?.contextPath == "./web")
        #expect(web.build?.dockerfile == "Dockerfile")
    }
}

@Suite("Planning")
struct PlanningTests {
    @Test("start order respects depends_on")
    func startOrder() throws {
        let project = try loadFixture()
        let order = try Planner.startOrder(project.file.services)
        let webIndex = order.firstIndex(of: "web")!
        #expect(order.firstIndex(of: "db")! < webIndex)
        #expect(order.firstIndex(of: "cache")! < webIndex)
    }

    @Test("cycle is detected")
    func cycle() throws {
        // a -> b -> a
        let yaml = """
            services:
              a:
                image: x
                depends_on: [b]
              b:
                image: y
                depends_on: [a]
            """
        let file = try ComposeFile.parse(yaml: yaml)
        #expect(throws: ComposeError.self) {
            _ = try Planner.startOrder(file.services)
        }
    }
}

@Suite("Interpolation")
struct InterpolationTests {
    let vars = ["NAME": "web", "EMPTY": "", "TAG": "1.2.3"]

    @Test("simple and braced forms")
    func simple() throws {
        #expect(try Interpolator.expand("$NAME:${TAG}", variables: vars) == "web:1.2.3")
    }

    @Test("escaped dollar")
    func escaped() throws {
        #expect(try Interpolator.expand("price $$5", variables: vars) == "price $5")
    }

    @Test("default operators")
    func defaults() throws {
        #expect(try Interpolator.expand("${MISSING:-fallback}", variables: vars) == "fallback")
        #expect(try Interpolator.expand("${EMPTY:-fallback}", variables: vars) == "fallback")
        #expect(try Interpolator.expand("${EMPTY-keep}", variables: vars) == "")  // set-but-empty
        #expect(try Interpolator.expand("${NAME:+yes}", variables: vars) == "yes")
        #expect(try Interpolator.expand("${MISSING:+yes}", variables: vars) == "")
    }

    @Test("required operator throws when unset")
    func required() throws {
        #expect(throws: ComposeError.self) {
            _ = try Interpolator.expand("${MISSING:?must be set}", variables: vars)
        }
    }

    @Test("unset variable becomes empty")
    func unset() throws {
        #expect(try Interpolator.expand("[${MISSING}]", variables: vars) == "[]")
    }
}

@Suite("EnvFile")
struct EnvFileTests {
    @Test("parses keys, quotes, exports, comments")
    func parse() {
        let env = EnvFile.parse(
            """
            # comment
            export FOO=bar
            QUOTED="hello world"
            SINGLE='raw $value'
            INLINE=value # trailing
            EMPTY=
            """)
        #expect(env["FOO"] == "bar")
        #expect(env["QUOTED"] == "hello world")
        #expect(env["SINGLE"] == "raw $value")
        #expect(env["INLINE"] == "value")
        #expect(env["EMPTY"] == "")
    }
}

@Suite("Corpus")
struct CorpusTests {
    /// Every spec-valid file in Fixtures/corpus must parse (this mirrors the CI
    /// schema-validation + docker-parity jobs: "ComposeKit accepts what the spec
    /// and docker accept").
    @Test("all corpus files parse")
    func parsesAll() throws {
        let dir =
            Bundle.module
            .url(forResource: "compose", withExtension: "yaml", subdirectory: "Fixtures")!
            .deletingLastPathComponent()
            .appendingPathComponent("corpus")
        let files = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "yaml" }
        #expect(!files.isEmpty)
        for url in files {
            let project = try Project.load(explicit: url.path, projectName: nil, cwd: dir)
            #expect(!project.file.services.isEmpty, "\(url.lastPathComponent) had no services")
        }
    }
}

@Suite("Profiles")
struct ProfileTests {
    /// app (no profile) + db (no profile); adminer/debug-shell are gated.
    private func services() throws -> [String: Service] {
        let url = Bundle.module.url(
            forResource: "profiles", withExtension: "yaml", subdirectory: "Fixtures/corpus")!
        return try ComposeFile.parse(yaml: String(contentsOf: url, encoding: .utf8)).services
    }

    @Test("no active profile enables only unprofiled services")
    func noProfile() throws {
        let enabled = Profiles.enabled(services: try services(), active: [])
        #expect(enabled == ["app", "db"])
    }

    @Test("active profile pulls in its services and their deps")
    func activeProfile() throws {
        let enabled = Profiles.enabled(services: try services(), active: ["tools"])
        // adminer joins, and its depends_on db; app/db stay (unprofiled).
        #expect(enabled == ["app", "db", "adminer"])
    }

    @Test("explicitly naming a profiled service enables it without the profile")
    func explicitOverridesProfile() throws {
        let enabled = Profiles.enabled(
            services: try services(), active: [], explicit: ["adminer"])
        // adminer + its dep db; app is not pulled in by an explicit selection.
        #expect(enabled == ["adminer", "db"])
    }

    @Test("COMPOSE_PROFILES is parsed into active profiles")
    func composeProfilesEnv() {
        let active = Project.resolveProfiles(
            flags: ["x"], variables: ["COMPOSE_PROFILES": "tools, debug"])
        #expect(active == ["x", "tools", "debug"])
    }
}

@Suite("Merge")
struct MergeTests {
    private func parse(_ yaml: String, _ name: String) throws -> Service {
        try ComposeFile.parse(yaml: yaml).services[name]!
    }

    @Test("override wins for scalars, maps merge, lists concatenate")
    func merge() throws {
        let base = try parse(
            """
            services:
              s:
                image: base:1
                command: ["a"]
                environment:
                  KEEP: base
                  OVERRIDE: base
                ports: ["1:1"]
            """, "s")
        let over = try parse(
            """
            services:
              s:
                command: ["b"]
                environment:
                  OVERRIDE: over
                  ADD: over
                ports: ["2:2"]
            """, "s")
        let r = over.merged(onto: base)
        #expect(r.image == "base:1")  // scalar from base (override absent)
        #expect(r.command?.values == ["b"])  // override wins
        let env = r.environment!.pairs()
        #expect(env.contains("KEEP=base"))
        #expect(env.contains("OVERRIDE=over"))
        #expect(env.contains("ADD=over"))
        #expect(r.ports?.count == 2)  // concatenated
    }
}

@Suite("Extends & include")
struct CompositionTests {
    private func load(_ name: String) throws -> Project {
        let url = Bundle.module.url(
            forResource: name, withExtension: "yaml", subdirectory: "Fixtures/corpus")!
        return try Project.load(
            explicit: url.path, projectName: nil, cwd: url.deletingLastPathComponent())
    }

    @Test("extends merges across files and locally")
    func extends() throws {
        let p = try load("extends-main")
        let web = p.file.services["web"]!
        #expect(web.image == "app:1.0")  // inherited from parts/base.yaml
        #expect(web.environment!.pairs().contains("LOG_LEVEL=debug"))  // override
        #expect(web.environment!.pairs().contains("REGION=us-east-1"))  // inherited
        #expect(web.ports?.count == 2)  // base 8080 + own 9090
        #expect(web.command?.values == ["./serve"])
        #expect(web.extends == nil)  // resolved away

        let worker = p.file.services["worker"]!
        #expect(worker.image == "app:1.0")  // via web -> base
        #expect(worker.command?.values == ["./work"])
        #expect(worker.environment!.pairs().contains("ROLE=worker"))
    }

    @Test("include pulls in services from another file")
    func include() throws {
        let p = try load("include-main")
        #expect(Set(p.file.services.keys) == ["app", "db"])
        #expect(p.file.services["db"]?.image == "postgres:16")
        #expect(p.file.include == nil)  // resolved away
    }

    @Test("extends cycle is detected")
    func cycle() throws {
        let file = try ComposeFile.parse(
            yaml: """
                services:
                  a:
                    image: x
                    extends: b
                  b:
                    image: y
                    extends: a
                """)
        #expect(throws: ComposeError.self) {
            _ = try Composition.resolveExtends(
                file, baseDir: URL(fileURLWithPath: "/tmp"), variables: [:])
        }
    }
}

@Suite("Interpolation operators & errors")
struct InterpolationOpsTests {
    let vars = ["NAME": "web", "EMPTY": "", "TAG": "1.2.3"]

    @Test("set-but-empty distinguishes colon from non-colon operators")
    func emptyOperators() throws {
        #expect(try Interpolator.expand("${EMPTY+yes}", variables: vars) == "yes")  // set -> rep
        #expect(try Interpolator.expand("${EMPTY:+yes}", variables: vars) == "")  // empty -> ""
        #expect(try Interpolator.expand("${EMPTY?x}", variables: vars) == "")  // set, no throw
        #expect(try Interpolator.expand("${MISSING+yes}", variables: vars) == "")  // unset -> ""
        #expect(try Interpolator.expand("${NAME-fb}", variables: vars) == "web")
        #expect(try Interpolator.expand("${MISSING-fb}", variables: vars) == "fb")
    }

    @Test("required operators throw appropriately")
    func required() {
        #expect(throws: ComposeError.self) { try Interpolator.expand("${MISSING?gone}", variables: vars) }
        #expect(throws: ComposeError.self) { try Interpolator.expand("${EMPTY:?empty}", variables: vars) }
    }

    @Test("malformed and non-reference dollars")
    func malformed() throws {
        #expect(throws: ComposeError.self) { try Interpolator.expand("${UNTERMINATED", variables: vars) }
        #expect(try Interpolator.expand("ends with $", variables: vars) == "ends with $")
        #expect(try Interpolator.expand("cost $5 today", variables: vars) == "cost $5 today")
    }
}

@Suite("KeyValueMap & scalars")
struct KeyValueMapTests {
    private func env(_ yaml: String) throws -> KeyValueMap {
        try ComposeFile.parse(yaml: yaml).services["s"]!.environment!
    }

    @Test("hostEnv pass-through fills bare keys and drops absent ones")
    func passThrough() throws {
        let e = try env("services:\n  s:\n    image: x\n    environment:\n      - PASSED\n      - SET=x\n")
        let withHost = e.pairs(hostEnv: ["PASSED": "v"])
        #expect(withHost.contains("PASSED=v"))
        #expect(withHost.contains("SET=x"))
        #expect(!e.pairs().contains { $0.hasPrefix("PASSED") })  // dropped without hostEnv
    }

    @Test("map form: null value falls back to hostEnv; scalar types normalize")
    func mapForms() throws {
        let e = try env(
            "services:\n  s:\n    image: x\n    environment:\n      PASSED:\n      B: true\n      I: 8080\n      D: 0.5\n")
        let pairs = e.pairs(hostEnv: ["PASSED": "v"])
        #expect(pairs.contains("PASSED=v"))  // null value <- hostEnv
        #expect(pairs.contains("B=true"))
        #expect(pairs.contains("I=8080"))
        #expect(pairs.contains("D=0.5"))
    }
}

@Suite("Project name sanitize")
struct SanitizeTests {
    @Test("normalizes to lowercase [a-z0-9_-]")
    func sanitize() {
        #expect(Project.sanitize("My App!!") == "my-app")
        #expect(Project.sanitize("a__b") == "a__b")
        #expect(Project.sanitize("--x--") == "x")
        #expect(Project.sanitize("!!!") == "compose")
        #expect(Project.sanitize("Foo.Bar/Baz") == "foo-bar-baz")
    }
}

@Suite("Merge depends_on")
struct MergeDependsOnTests {
    @Test("union with override condition winning")
    func union() throws {
        let base = try ComposeFile.parse(
            yaml: "services:\n  s:\n    image: x\n    depends_on: [db, cache]\n").services["s"]!
        let over = try ComposeFile.parse(
            yaml: "services:\n  s:\n    depends_on:\n      db:\n        condition: service_healthy\n")
            .services["s"]!
        let m = over.merged(onto: base)
        #expect(Set(m.depends_on?.names ?? []) == ["db", "cache"])
        #expect(m.depends_on?.condition(for: "db") == "service_healthy")  // override wins
        #expect(m.depends_on?.condition(for: "cache") == "service_started")  // default kept
    }
}

@Suite("Planner dangling deps")
struct PlannerDanglingTests {
    @Test("depends_on to an undeclared service is ignored")
    func dangling() throws {
        let file = try ComposeFile.parse(
            yaml: "services:\n  a:\n    image: x\n    depends_on: [ghost]\n")
        #expect(try Planner.startOrder(file.services) == ["a"])
    }
}

@Suite("EnvFile edge cases")
struct EnvFileEdgeTests {
    @Test("inline comments and quote escapes")
    func edges() {
        #expect(EnvFile.parse("URL=http://x#frag")["URL"] == "http://x#frag")  // no space -> not a comment
        #expect(EnvFile.parse("URL=http://x #frag")["URL"] == "http://x")  // space -> comment
        #expect(EnvFile.parse("M=\"a\\nb\"")["M"] == "a\nb")  // double quotes unescape \n
        #expect(EnvFile.parse("S='a\\nb'")["S"] == "a\\nb")  // single quotes keep literal
    }
}

@Suite("Health")
struct HealthTests {
    @Test("depends_on condition is read")
    func condition() throws {
        let yaml = """
            services:
              web:
                image: x
                depends_on:
                  db:
                    condition: service_healthy
              db:
                image: y
            """
        let file = try ComposeFile.parse(yaml: yaml)
        #expect(file.services["web"]?.depends_on?.condition(for: "db") == "service_healthy")
    }
}

@Suite("Error paths")
struct ErrorPathTests {
    @Test("load with a missing env file throws envFileNotFound")
    func missingEnvFile() {
        let url = Bundle.module.url(
            forResource: "compose", withExtension: "yaml", subdirectory: "Fixtures")!
        #expect(throws: ComposeError.self) {
            _ = try Project.load(
                explicit: url.path, projectName: nil, cwd: url.deletingLastPathComponent(),
                envFile: "/no/such/env")
        }
    }

    @Test("extends to an undeclared service throws")
    func unknownExtends() throws {
        let file = try ComposeFile.parse(
            yaml: "services:\n  a:\n    image: x\n    extends: ghost\n")
        #expect(throws: ComposeError.self) {
            _ = try Composition.resolveExtends(
                file, baseDir: URL(fileURLWithPath: "/tmp"), variables: [:])
        }
    }
}

@Suite("Multi-file load")
struct MultiFileTests {
    private func write(_ files: [String: String], _ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ckmf-\(tag)-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in files {
            try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test("explicit files merge in order: later wins, lists concatenate")
    func explicitMerge() throws {
        let dir = try write([
            "base.yaml":
                "name: app\nservices:\n  web:\n    image: nginx:1\n    ports: [\"80:80\"]\n    environment:\n      A: base\n",
            "override.yaml":
                "services:\n  web:\n    image: nginx:2\n    ports: [\"443:443\"]\n    environment:\n      B: over\n",
        ], "explicit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try Project.load(files: ["base.yaml", "override.yaml"], projectName: nil, cwd: dir)
        let web = p.file.services["web"]!
        #expect(web.image == "nginx:2")  // override wins
        #expect(web.ports?.count == 2)  // concatenated
        let env = web.environment!.pairs()
        #expect(env.contains("A=base") && env.contains("B=over"))
        #expect(p.name == "app")
    }

    @Test("compose.override.yaml is auto-merged when no files are given")
    func autoOverride() throws {
        let dir = try write([
            "compose.yaml": "name: app\nservices:\n  web:\n    image: nginx:1\n",
            "compose.override.yaml":
                "services:\n  web:\n    image: nginx:2\n    environment:\n      DEBUG: \"1\"\n",
        ], "auto")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try Project.load(files: [], projectName: nil, cwd: dir)
        let web = p.file.services["web"]!
        #expect(web.image == "nginx:2")  // override wins
        #expect(web.environment?.pairs().contains("DEBUG=1") == true)
    }

    @Test("explicit files disable override auto-loading")
    func explicitNoAutoOverride() throws {
        let dir = try write([
            "compose.yaml": "name: app\nservices:\n  web:\n    image: nginx:1\n",
            "compose.override.yaml": "services:\n  web:\n    image: nginx:2\n",
        ], "noauto")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try Project.load(files: ["compose.yaml"], projectName: nil, cwd: dir)
        #expect(p.file.services["web"]?.image == "nginx:1")  // override NOT applied
    }
}
