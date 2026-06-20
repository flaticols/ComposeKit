//===----------------------------------------------------------------------===//
// High-level Compose operations, built on ContainerTranslator + ContainerRunner.
//===----------------------------------------------------------------------===//

import ComposeKit
import Foundation

public struct Orchestrator: Sendable {
    public let project: Project
    public let runner: ContainerRunner
    public let translator: ContainerTranslator

    public init(project: Project, runner: ContainerRunner) {
        self.project = project
        self.runner = runner
        self.translator = ContainerTranslator(
            project: project.name,
            baseDirectory: project.baseDirectory,
            hostEnv: project.variables
        )
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("container-compose: warning: \(message)\n".utf8))
    }

    private func info(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    // MARK: - up

    public func up(build: Bool, only services: [String]) throws {
        try validate(services)
        let selected = project.enabledServices(explicit: services)
        try ensureNetworks()
        try ensureVolumes()

        // Services that a selected service depends on with
        // `condition: service_completed_successfully` — run these to completion.
        let oneShot = completedSuccessfullyTargets(selected: selected)
        let resolved = resolveFileObjects(selected: selected)

        let order = try Planner.startOrder(project.file.services).filter { selected.contains($0) }
        for name in order {
            guard let svc = project.file.services[name] else { continue }
            let image = try imageForService(
                name: name, svc: svc, forceBuild: build, buildSecrets: resolved.secrets)
            warnUnsupported(name: name, svc: svc)

            // Wait on any `depends_on: condition: service_healthy` dependencies.
            try gateDependencies(of: name, svc, selected: selected)

            // Recreate semantics: remove any stale container with the same name.
            let cname = translator.containerName(service: name, declared: svc.container_name)
            runner.runSilently(["delete", "--force", cname])

            // One-shot dependency: run attached and use the exit code as the gate
            // (`container` has no `wait`); a non-zero exit aborts `up`. Topological
            // order guarantees it completes before any dependent starts.
            if oneShot.contains(name) {
                info("Running \(cname) (one-shot) ...")
                let args = translator.runArgs(
                    service: name, svc, image: image, detach: false, files: resolved)
                let status = try runner.run(args)
                if status != 0 { throw ComposeError.dependencyFailed(name, status) }
            } else {
                info("Creating \(cname) ...")
                try runner.runChecked(
                    translator.runArgs(service: name, svc, image: image, files: resolved))
            }
        }
    }

    /// Names of services that any selected service depends on with the
    /// `service_completed_successfully` condition.
    private func completedSuccessfullyTargets(selected: Set<String>) -> Set<String> {
        var targets = Set<String>()
        for name in selected {
            guard let deps = project.file.services[name]?.depends_on else { continue }
            for dep in deps.names
            where selected.contains(dep)
                && deps.condition(for: dep) == "service_completed_successfully" {
                targets.insert(dep)
            }
        }
        return targets
    }

    /// Block on `service_healthy` dependencies that were also selected for `up`.
    private func gateDependencies(of name: String, _ svc: Service, selected: Set<String>) throws {
        guard let deps = svc.depends_on else { return }
        for dep in deps.names where selected.contains(dep) {
            guard deps.condition(for: dep) == "service_healthy" else { continue }
            guard let depSvc = project.file.services[dep] else { continue }
            let depContainer = translator.containerName(service: dep, declared: depSvc.container_name)
            if let hc = depSvc.healthcheck, hc.disable != true,
                let test = hc.test, HealthChecker.execArguments(for: test) != nil
            {
                info("Waiting for '\(dep)' to be healthy ...")
                try HealthChecker(runner: runner).waitHealthy(container: depContainer, health: hc)
            } else {
                warn(
                    "service '\(name)': depends_on '\(dep)' wants service_healthy but "
                        + "'\(dep)' defines no healthcheck; starting without gating")
            }
        }
    }

    /// Resolve every config/secret source referenced by a selected service to a
    /// host file path: `file:` is resolved against the project dir;
    /// `content:`/`environment:` are materialized to a temp file. `external:`,
    /// undefined, and source-less entries are warned and skipped, as are
    /// uid/gid/mode (bind mounts can't enforce them).
    private func resolveFileObjects(selected: Set<String>) -> ContainerTranslator.ResolvedFileObjects {
        var configs: [String: String] = [:]
        var secrets: [String: String] = [:]

        func resolve(
            kind: String,
            defs: [String: FileObjectSpec?]?,
            refsFor: (Service) -> [ServiceFileRef]?,
            into out: inout [String: String]
        ) {
            var referenced = Set<String>()
            for name in selected {
                guard let svc = project.file.services[name] else { continue }
                for ref in refsFor(svc) ?? [] {
                    referenced.insert(ref.source)
                    if case .long(let l) = ref, l.uid != nil || l.gid != nil || l.mode != nil {
                        warn("service '\(name)': \(kind) '\(ref.source)' uid/gid/mode "
                            + "are not enforced by container")
                    }
                }
            }
            for source in referenced.sorted() {
                guard let spec = defs?[source] ?? nil else {
                    warn("\(kind) '\(source)' is referenced but not defined; skipping")
                    continue
                }
                if spec.external?.isExternal == true {
                    warn("\(kind) '\(source)' is external; container cannot resolve it, skipping")
                } else if let file = spec.file {
                    out[source] = translator.resolvePath(file)
                } else if let content = spec.content {
                    if let p = materialize(kind: kind, name: source, content: content) { out[source] = p }
                } else if let envName = spec.environment {
                    let value = project.variables[envName] ?? ""
                    if let p = materialize(kind: kind, name: source, content: value) { out[source] = p }
                } else {
                    warn("\(kind) '\(source)' has no file/content/environment source; skipping")
                }
            }
        }

        // Secret sources come from both service `secrets:` and `build.secrets`.
        resolve(
            kind: "secret", defs: project.file.secrets,
            refsFor: { ($0.secrets ?? []) + ($0.build?.long?.secrets ?? []) }, into: &secrets)
        resolve(kind: "config", defs: project.file.configs, refsFor: { $0.configs }, into: &configs)
        return .init(configs: configs, secrets: secrets)
    }

    /// Write inline `content:`/`environment:` source data to a temp file and
    /// return its path. During a dry run nothing is written (the path is still
    /// returned so the planned mount is visible).
    private func materialize(kind: String, name: String, content: String) -> String? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("composekit-\(project.name)", isDirectory: true)
            .appendingPathComponent("\(kind)s", isDirectory: true)
        let url = dir.appendingPathComponent(name)
        if runner.dryRun { return url.path }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            warn("\(kind) '\(name)': failed to materialize content (\(error)); skipping")
            return nil
        }
    }

    private func imageForService(
        name: String, svc: Service, forceBuild: Bool, buildSecrets: [String: String]
    ) throws -> String {
        if svc.build != nil, forceBuild || svc.image == nil {
            if let buildArgs = translator.buildArgs(
                service: name, svc, resolvedSecrets: buildSecrets)
            {
                info("Building \(name) ...")
                try runner.runChecked(buildArgs)
            }
            return svc.image ?? translator.builtImageTag(service: name)
        }
        guard let image = svc.image else {
            throw ComposeError.serviceMissingImage(name)
        }
        return image
    }

    // MARK: - down

    public func down(removeVolumes: Bool) throws {
        // Stop & remove in reverse dependency order.
        let order = try Planner.startOrder(project.file.services).reversed()
        for name in order {
            guard let svc = project.file.services[name] else { continue }
            let cname = translator.containerName(service: name, declared: svc.container_name)
            info("Removing \(cname) ...")
            runner.runSilently(["stop", cname])
            runner.runSilently(["delete", "--force", cname])
        }

        // Remove project networks (default + declared).
        var networks = [translator.defaultNetwork]
        networks += (project.file.networks?.keys ?? Dictionary<String, NetworkSpec?>().keys).map {
            translator.networkName($0)
        }
        for net in networks {
            runner.runSilently(["network", "delete", net])
        }

        if removeVolumes {
            for volName in project.file.volumes?.keys ?? Dictionary<String, VolumeSpec?>().keys {
                runner.runSilently(["volume", "delete", translator.volumeName(volName)])
            }
        }
    }

    // MARK: - ps

    /// List this project's containers. Uses a name-prefix filter over
    /// `container list` output (the CLI's JSON schema is not depended upon).
    public func ps(all: Bool) throws {
        var args = ["list"]
        if all { args.append("--all") }
        let (status, out) = try runner.capture(args)
        guard status == 0 else { throw ContainerRunner.RunnerError.nonZeroExit(command: args, status: status) }

        let prefix = "\(project.name)-"
        let declaredNames = Set(
            project.file.services.map { name, svc in
                translator.containerName(service: name, declared: svc.container_name)
            }
        )
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.first else { return }
        print(header)
        for line in lines.dropFirst() {
            let belongs = line.contains(prefix) || declaredNames.contains { line.contains($0) }
            if belongs { print(line) }
        }
    }

    // MARK: - logs

    public func logs(follow: Bool, only services: [String]) throws {
        let selected = try select(services).sorted()
        if follow && selected.count > 1 {
            warn("--follow with multiple services tails them sequentially; pass one service to stream live")
        }
        for name in selected {
            guard let svc = project.file.services[name] else { continue }
            let cname = translator.containerName(service: name, declared: svc.container_name)
            var args = ["logs"]
            if follow { args.append("--follow") }
            args.append(cname)
            _ = try? runner.run(args)
        }
    }

    // MARK: - shared helpers

    private func select(_ services: [String]) throws -> Set<String> {
        guard !services.isEmpty else { return Set(project.file.services.keys) }
        try validate(services)
        return Set(services)
    }

    /// Throw on any name that isn't a declared service.
    private func validate(_ services: [String]) throws {
        for s in services where project.file.services[s] == nil {
            throw ComposeError.unknownService(s)
        }
    }

    private func ensureNetworks() throws {
        var toCreate: [(name: String, spec: NetworkSpec?)] = [(translator.defaultNetwork, nil)]
        for (declared, spec) in project.file.networks ?? [:] {
            // External networks are assumed to already exist.
            if spec?.external?.isExternal == true { continue }
            toCreate.append((translator.networkName(declared), spec))
        }
        for (name, spec) in toCreate {
            var args = ["network", "create"]
            if spec?.`internal` == true { args.append("--internal") }
            if let subnet = spec?.subnet { args += ["--subnet", subnet] }
            args.append(name)
            // Best-effort and idempotent: an existing network is silently reused
            // (Docker-compatible). A genuine failure surfaces when `run` uses it.
            runner.runSilently(args)
        }
    }

    private func ensureVolumes() throws {
        // Declared top-level named volumes.
        var names = Set<String>()
        for (declared, spec) in project.file.volumes ?? [:] {
            if spec?.external?.isExternal == true { continue }
            names.insert(declared)
        }
        for name in names.sorted() {
            // Idempotent: an existing volume is reused.
            runner.runSilently(["volume", "create", translator.volumeName(name)])
        }
    }

    private func warnUnsupported(name: String, svc: Service) {
        if svc.restart != nil {
            warn("service '\(name)': 'restart' is recorded as a label but not enforced by container")
        }
        if svc.privileged == true {
            warn("service '\(name)': 'privileged' has no container equivalent and is ignored")
        }
        // Popular fields `container` cannot express — decoded so the file parses,
        // but flagged so the gap is visible rather than silently dropped.
        var ignored: [String] = []
        if svc.hostname != nil { ignored.append("hostname") }
        if svc.extra_hosts != nil { ignored.append("extra_hosts") }
        if svc.network_mode != nil { ignored.append("network_mode") }
        if svc.devices != nil { ignored.append("devices") }
        if svc.sysctls != nil { ignored.append("sysctls") }
        if svc.security_opt != nil { ignored.append("security_opt") }
        if svc.stop_signal != nil { ignored.append("stop_signal") }
        if svc.stop_grace_period != nil { ignored.append("stop_grace_period") }
        if svc.gpus != nil { ignored.append("gpus") }
        if !ignored.isEmpty {
            warn("service '\(name)': \(ignored.joined(separator: ", ")) "
                + "\(ignored.count == 1 ? "has" : "have") no container equivalent and "
                + "\(ignored.count == 1 ? "is" : "are") ignored")
        }

        // Build fields `container build` cannot express.
        var build: [String] = []
        if svc.build?.long?.ssh != nil { build.append("build.ssh") }
        if svc.build?.long?.network != nil { build.append("build.network") }
        if svc.build?.long?.cache_from != nil { build.append("build.cache_from") }
        if !build.isEmpty {
            warn("service '\(name)': \(build.joined(separator: ", ")) "
                + "\(build.count == 1 ? "is" : "are") not supported by container build and "
                + "\(build.count == 1 ? "is" : "are") ignored")
        }
    }
}
