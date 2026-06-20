import Foundation
import Testing

@testable import ComposeKit
@testable import ComposeKitContainer

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

@Suite("Translation")
struct TranslationTests {
    private func translator() -> ContainerTranslator {
        ContainerTranslator(project: "demo", baseDirectory: URL(fileURLWithPath: "/proj"), hostEnv: [:])
    }

    @Test("run args carry name, labels, network, ports")
    func runArgs() throws {
        let project = try loadFixture()
        let web = project.file.services["web"]!
        let args = translator().runArgs(service: "web", web, image: "demo-web:latest")
        #expect(args.contains("run"))
        #expect(args.contains("--detach"))
        #expect(adjacent(args, "--name", "demo-web"))
        #expect(adjacent(args, "--publish", "8080:80"))
        #expect(adjacent(args, "--network", "demo-backend"))
        #expect(adjacent(args, "--network", "demo-frontend"))
        #expect(adjacent(args, "--cpus", "0.5"))
        #expect(adjacent(args, "--memory", "256m"))
        // image precedes the command
        let imageIdx = args.firstIndex(of: "demo-web:latest")!
        let nodeIdx = args.firstIndex(of: "node")!
        #expect(imageIdx < nodeIdx)
    }

    @Test("named volume source is project-scoped, bind path is resolved")
    func volumes() throws {
        let project = try loadFixture()
        let db = project.file.services["db"]!
        let args = translator().runArgs(service: "db", db, image: "postgres:16")
        #expect(adjacent(args, "--volume", "demo-dbdata:/var/lib/postgresql/data"))

        let web = project.file.services["web"]!
        let webArgs = translator().runArgs(service: "web", web, image: "demo-web:latest")
        #expect(webArgs.contains { $0.hasSuffix("/proj/web/static:/app/static:ro") })
    }

    @Test("short string command runs through a shell")
    func shellCommand() throws {
        let yaml = """
            services:
              x:
                image: alpine
                command: echo hello
            """
        let file = try ComposeFile.parse(yaml: yaml)
        let args = translator().runArgs(service: "x", file.services["x"]!, image: "alpine")
        #expect(adjacent(args, "/bin/sh", "-c"))
        #expect(args.last == "echo hello")
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

@Suite("Health")
struct HealthTests {
    @Test("duration parsing")
    func durations() {
        #expect(HealthChecker.seconds("30s") == 30)
        #expect(HealthChecker.seconds("1m30s") == 90)
        #expect(HealthChecker.seconds("500ms") == 0.5)
        #expect(HealthChecker.seconds("2") == 2)
        #expect(HealthChecker.seconds(nil) == nil)
    }

    @Test("test translation: CMD, CMD-SHELL, NONE, string")
    func translation() {
        #expect(HealthChecker.execArguments(for: .list(["CMD", "curl", "-f", "x"])) == ["curl", "-f", "x"])
        #expect(HealthChecker.execArguments(for: .list(["CMD-SHELL", "curl -f x"])) == ["/bin/sh", "-c", "curl -f x"])
        #expect(HealthChecker.execArguments(for: .list(["NONE"])) == nil)
        #expect(HealthChecker.execArguments(for: .string("pg_isready")) == ["/bin/sh", "-c", "pg_isready"])
    }

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

@Suite("New-field translation")
struct NewFieldTests {
    private func worker() throws -> Service {
        let url = Bundle.module.url(
            forResource: "resources", withExtension: "yaml", subdirectory: "Fixtures/corpus")!
        return try ComposeFile.parse(yaml: String(contentsOf: url, encoding: .utf8))
            .services["worker"]!
    }

    @Test("ulimits, shm_size, dns, runtime, tty translate to container flags")
    func translates() throws {
        let t = ContainerTranslator(
            project: "p", baseDirectory: URL(fileURLWithPath: "/p"), hostEnv: [:])
        let args = t.runArgs(service: "worker", try worker(), image: "app:latest")
        #expect(adjacent(args, "--ulimit", "nofile=1024:524288"))
        #expect(adjacent(args, "--ulimit", "nproc=65535"))
        #expect(adjacent(args, "--shm-size", "128m"))
        #expect(adjacent(args, "--runtime", "runc"))
        #expect(adjacent(args, "--dns-search", "corp.example.com"))
        #expect(adjacent(args, "--dns-option", "timeout:2"))
        #expect(args.contains("--interactive"))
        #expect(args.contains("--tty"))
    }

    @Test("extra_hosts normalizes list and map forms to host:ip")
    func extraHosts() {
        #expect(ExtraHosts.list(["a:1.1.1.1"]).entries == ["a:1.1.1.1"])
        #expect(
            ExtraHosts.map(["b": ComposeScalar("2.2.2.2"), "a": ComposeScalar("1.1.1.1")]).entries
                == ["a:1.1.1.1", "b:2.2.2.2"])
    }
}

@Suite("Configs & secrets")
struct FileObjectTests {
    private func appService() throws -> Service {
        let url = Bundle.module.url(
            forResource: "configs-secrets", withExtension: "yaml", subdirectory: "Fixtures/corpus")!
        return try ComposeFile.parse(yaml: String(contentsOf: url, encoding: .utf8)).services["app"]!
    }

    @Test("short and long refs parse")
    func parseRefs() throws {
        let app = try appService()
        #expect(app.secrets?.map(\.source).sorted() == ["api_key", "db_password"])
        #expect(app.configs?.map(\.source).sorted() == ["app_config", "nginx_conf"])
    }

    @Test("configs/secrets become read-only bind mounts at the right targets")
    func mounts() throws {
        let t = ContainerTranslator(
            project: "p", baseDirectory: URL(fileURLWithPath: "/p"), hostEnv: [:])
        let files = ContainerTranslator.ResolvedFileObjects(
            configs: ["app_config": "/h/app.yaml", "nginx_conf": "/h/nginx.conf"],
            secrets: ["db_password": "/h/db", "api_key": "/h/api"])
        let args = t.runArgs(service: "app", try appService(), image: "app:latest", files: files)
        #expect(adjacent(args, "--volume", "/h/db:/run/secrets/db_password:ro"))  // short secret default
        #expect(adjacent(args, "--volume", "/h/api:/etc/api/key:ro"))  // long secret custom target
        #expect(adjacent(args, "--volume", "/h/app.yaml:/etc/app/config.yaml:ro"))  // long config target
        #expect(adjacent(args, "--volume", "/h/nginx.conf:/nginx_conf:ro"))  // short config -> /name
        // Mounts precede the image.
        let vol = args.firstIndex(of: "/h/db:/run/secrets/db_password:ro")!
        #expect(vol < args.firstIndex(of: "app:latest")!)
    }

    @Test("detach:false omits --detach for one-shot runs")
    func detachFlag() throws {
        let t = ContainerTranslator(
            project: "p", baseDirectory: URL(fileURLWithPath: "/p"), hostEnv: [:])
        let svc = try ComposeFile.parse(yaml: "services:\n  x:\n    image: a\n").services["x"]!
        #expect(!t.runArgs(service: "x", svc, image: "a", detach: false).contains("--detach"))
        #expect(t.runArgs(service: "x", svc, image: "a").contains("--detach"))
    }
}

// .serialized: these mutate the process-global CONTAINER_CLI env var.
@Suite("Completed-successfully gating", .serialized)
struct OneShotTests {
    @Test("dry-run up completes for a stack using service_completed_successfully")
    func dryRunUp() throws {
        // local-dev.yaml gates web on migrate (service_completed_successfully);
        // a dry run exercises the one-shot detection + attached-run branch.
        let url = Bundle.module.url(
            forResource: "local-dev", withExtension: "yaml", subdirectory: "Fixtures/corpus")!
        let project = try Project.load(
            explicit: url.path, projectName: nil, cwd: url.deletingLastPathComponent())
        let orch = Orchestrator(project: project, runner: ContainerRunner(dryRun: true))
        try orch.up(build: false, only: [])
    }

    @Test("a failing one-shot dependency aborts up")
    func failingOneShotAborts() throws {
        // Shim `container` that always exits non-zero; the one-shot `a` then
        // fails and `up` must throw dependencyFailed before `b` is created.
        let shim = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-fail-shim-\(getpid())")
        try "#!/bin/sh\nexit 7\n".write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        defer { try? FileManager.default.removeItem(at: shim) }

        setenv("CONTAINER_CLI", shim.path, 1)
        let runner = ContainerRunner()  // captures the shim path at init
        unsetenv("CONTAINER_CLI")

        let yaml = """
            services:
              a:
                image: alpine
                command: ["false"]
              b:
                image: alpine
                depends_on:
                  a:
                    condition: service_completed_successfully
            """
        let project = Project(
            name: "t", file: try ComposeFile.parse(yaml: yaml),
            baseDirectory: URL(fileURLWithPath: "/tmp"), variables: [:])
        let orch = Orchestrator(project: project, runner: runner)

        do {
            try orch.up(build: false, only: [])
            Issue.record("expected up to throw dependencyFailed")
        } catch let ComposeError.dependencyFailed(name, status) {
            #expect(name == "a")
            #expect(status == 7)
        }
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

@Suite("Build translation")
struct BuildTests {
    @Test("advanced build fields translate to container build flags")
    func buildArgs() throws {
        let url = Bundle.module.url(
            forResource: "build-advanced", withExtension: "yaml", subdirectory: "Fixtures/corpus")!
        let svc = try ComposeFile.parse(yaml: String(contentsOf: url, encoding: .utf8))
            .services["app"]!
        let t = ContainerTranslator(
            project: "p", baseDirectory: URL(fileURLWithPath: "/p"), hostEnv: [:])
        let args = t.buildArgs(service: "app", svc, resolvedSecrets: ["build_token": "/h/tok"])!
        #expect(args.contains("--no-cache"))
        #expect(adjacent(args, "--label", "com.example.tier=web"))
        #expect(adjacent(args, "--secret", "id=build_token,src=/h/tok"))
    }
}

// .serialized: mutates the process-global CONTAINER_CLI env var.
@Suite("Lifecycle commands", .serialized)
struct LifecycleTests {
    /// Run `body` against an Orchestrator whose `container` is a shim that records
    /// each invocation, and return the recorded command lines.
    private func capture(_ tag: String, _ body: (Orchestrator) throws -> Void) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory
        let log = dir.appendingPathComponent("ck-log-\(tag)-\(getpid()).txt")
        let shim = dir.appendingPathComponent("ck-shim-\(tag)-\(getpid()).sh")
        try? FileManager.default.removeItem(at: log)
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(log.path)'\nexit 0\n"
            .write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        defer {
            try? FileManager.default.removeItem(at: shim)
            try? FileManager.default.removeItem(at: log)
        }

        setenv("CONTAINER_CLI", shim.path, 1)
        let runner = ContainerRunner()  // captures the shim path at init
        unsetenv("CONTAINER_CLI")

        let yaml = """
            services:
              db:
                image: postgres:16
              app:
                build: .
                depends_on: [db]
            """
        let project = Project(
            name: "proj", file: try ComposeFile.parse(yaml: yaml),
            baseDirectory: URL(fileURLWithPath: "/tmp"), variables: [:])
        try body(Orchestrator(project: project, runner: runner))
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    @Test("exec passes -i/-t and the command into the service container")
    func exec() throws {
        let lines = try capture("exec") {
            _ = try $0.exec(service: "db", command: ["psql", "-U", "app"], interactive: true, tty: true)
        }
        #expect(lines.contains("exec --interactive --tty proj-db psql -U app"))
    }

    @Test("pull fetches image services and skips build-only ones")
    func pull() throws {
        let lines = try capture("pull") { try $0.pull(only: []) }
        #expect(lines.contains("image pull postgres:16"))
        #expect(!lines.contains { $0.contains("proj-app") })  // app builds locally
    }

    @Test("stop runs in reverse dependency order")
    func stop() throws {
        let lines = try capture("stop") { try $0.stop(only: []) }
        let app = lines.firstIndex(of: "stop proj-app")
        let db = lines.firstIndex(of: "stop proj-db")
        #expect(app != nil && db != nil && app! < db!)  // dependent stops first
    }

    @Test("restart stops everything before starting anything")
    func restart() throws {
        let lines = try capture("restart") { try $0.restart(only: []) }
        #expect(lines.contains("stop proj-db"))
        #expect(lines.contains("start proj-db"))
        let lastStop = lines.lastIndex { $0.hasPrefix("stop ") }!
        let firstStart = lines.firstIndex { $0.hasPrefix("start ") }!
        #expect(lastStop < firstStart)
    }
}

/// True if `value` immediately follows `flag` somewhere in `args`.
private func adjacent(_ args: [String], _ flag: String, _ value: String) -> Bool {
    for i in args.indices.dropLast() where args[i] == flag && args[i + 1] == value {
        return true
    }
    return false
}
