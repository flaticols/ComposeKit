// Deep-merge rules shared by `extends` and `include`.
//
// Pragmatic, Compose-flavored semantics (override = the winning side):
//   - scalars and nested objects: override replaces base when present
//   - maps (environment, labels, sysctls): merged by key, override wins
//   - sequences (ports, volumes, ...): concatenated (base then override)
//   - depends_on: unioned, override's condition wins per service
//
// This matches Docker for the common local-dev cases. It is not a full
// implementation of every field-specific rule in the spec.

extension KeyValueMap {
    /// Merge two key/value collections, with `self` (the override) winning per key.
    func merging(over base: KeyValueMap?) -> KeyValueMap {
        guard let base else { return self }
        var map = base.asMap()
        for (key, value) in asMap() { map.updateValue(value, forKey: key) }
        return .map(map)
    }

    /// Normalize to a `key -> value?` map (a bare list entry becomes a nil value).
    func asMap() -> [String: ComposeScalar?] {
        switch self {
        case .map(let m):
            return m
        case .list(let arr):
            var d: [String: ComposeScalar?] = [:]
            for item in arr {
                if let eq = item.firstIndex(of: "=") {
                    d[String(item[..<eq])] = ComposeScalar(String(item[item.index(after: eq)...]))
                } else {
                    d.updateValue(nil, forKey: item)
                }
            }
            return d
        }
    }
}

/// Concatenate two optional arrays (base first), preserving nil when both are nil.
func mergedList<T>(_ base: [T]?, _ override: [T]?) -> [T]? {
    switch (base, override) {
    case (nil, nil): return nil
    case (let b?, nil): return b
    case (nil, let o?): return o
    case (let b?, let o?): return b + o
    }
}

/// Override-wins-per-key merge of two optional dictionaries.
func mergedDict<T>(_ base: [String: T]?, _ override: [String: T]?) -> [String: T]? {
    guard let base else { return override }
    guard let override else { return base }
    var d = base
    for (k, v) in override { d[k] = v }
    return d
}

/// Union of two `depends_on` declarations; the override's condition wins per name.
func mergedDependsOn(_ base: DependsOn?, _ override: DependsOn?) -> DependsOn? {
    guard let base else { return override }
    guard let override else { return base }
    var map: [String: DependsOn.Dependency] = [:]
    func absorb(_ d: DependsOn) {
        switch d {
        case .list(let names):
            for n in names where map[n] == nil {
                map[n] = DependsOn.Dependency(condition: nil, required: nil)
            }
        case .map(let m):
            for (k, v) in m { map[k] = v }
        }
    }
    absorb(base)
    absorb(override)
    return .map(map)
}

extension Service {
    /// Merge `self` (the override) on top of `base`, returning the combined service.
    func merged(onto base: Service) -> Service {
        var r = base

        // Scalars and nested objects: override wins when present.
        r.image = image ?? base.image
        r.build = build ?? base.build
        r.command = command ?? base.command
        r.entrypoint = entrypoint ?? base.entrypoint
        r.env_file = env_file ?? base.env_file
        r.networks = networks ?? base.networks
        r.working_dir = working_dir ?? base.working_dir
        r.user = user ?? base.user
        r.container_name = container_name ?? base.container_name
        r.restart = restart ?? base.restart
        r.dns = dns ?? base.dns
        r.tmpfs = tmpfs ?? base.tmpfs
        r.read_only = read_only ?? base.read_only
        r.`init` = `init` ?? base.`init`
        r.platform = platform ?? base.platform
        r.privileged = privileged ?? base.privileged
        r.deploy = deploy ?? base.deploy
        r.cpus = cpus ?? base.cpus
        r.mem_limit = mem_limit ?? base.mem_limit
        r.healthcheck = healthcheck ?? base.healthcheck
        r.tty = tty ?? base.tty
        r.stdin_open = stdin_open ?? base.stdin_open
        r.ulimits = ulimits ?? base.ulimits
        r.shm_size = shm_size ?? base.shm_size
        r.dns_search = dns_search ?? base.dns_search
        r.runtime = runtime ?? base.runtime
        r.hostname = hostname ?? base.hostname
        r.extra_hosts = extra_hosts ?? base.extra_hosts
        r.network_mode = network_mode ?? base.network_mode
        r.stop_signal = stop_signal ?? base.stop_signal
        r.stop_grace_period = stop_grace_period ?? base.stop_grace_period
        r.pull_policy = pull_policy ?? base.pull_policy
        r.gpus = gpus ?? base.gpus

        // Maps: merged by key.
        r.environment = environment?.merging(over: base.environment) ?? base.environment
        r.labels = labels?.merging(over: base.labels) ?? base.labels
        r.sysctls = sysctls?.merging(over: base.sysctls) ?? base.sysctls

        // Sequences: concatenated.
        r.ports = mergedList(base.ports, ports)
        r.expose = mergedList(base.expose, expose)
        r.volumes = mergedList(base.volumes, volumes)
        r.cap_add = mergedList(base.cap_add, cap_add)
        r.cap_drop = mergedList(base.cap_drop, cap_drop)
        r.dns_opt = mergedList(base.dns_opt, dns_opt)
        r.devices = mergedList(base.devices, devices)
        r.security_opt = mergedList(base.security_opt, security_opt)
        r.profiles = mergedList(base.profiles, profiles)
        r.configs = mergedList(base.configs, configs)
        r.secrets = mergedList(base.secrets, secrets)

        r.depends_on = mergedDependsOn(base.depends_on, depends_on)

        // `extends` is resolved away; never carry it into the result.
        r.extends = nil
        return r
    }
}

extension ComposeFile {
    /// Merge `self` (the override) on top of `base`. Services present in both are
    /// merged service-wise; top-level maps merge by key. Used for `include`.
    func merged(onto base: ComposeFile) -> ComposeFile {
        var r = base
        r.version = version ?? base.version
        r.name = name ?? base.name

        var services = base.services
        for (key, svc) in self.services {
            services[key] = base.services[key].map { svc.merged(onto: $0) } ?? svc
        }
        r.services = services

        r.networks = mergedDict(base.networks, networks)
        r.volumes = mergedDict(base.volumes, volumes)
        r.configs = mergedDict(base.configs, configs)
        r.secrets = mergedDict(base.secrets, secrets)
        r.include = nil
        return r
    }
}
