import Foundation
import Yams

/// A decoded Compose file: services plus the top-level networks, volumes,
/// configs, and secrets.
///
/// This is intentionally a pragmatic subset of the
/// [compose-spec](https://github.com/compose-spec/compose-spec). Fields that
/// `container` cannot yet express are still decoded (so real files parse) but
/// may be ignored at translation time — see `ContainerTranslator` for what is
/// actually applied. Decode one with ``parse(yaml:)``, or load and resolve a
/// whole project with ``Project/load(explicit:projectName:cwd:envFile:profiles:)``.
public struct ComposeFile: Decodable, Sendable {
    /// Deprecated and ignored, but still common in the wild — decoded so files
    /// that carry it don't surprise anyone (Compose itself only warns).
    public var version: String?
    public var name: String?
    public var services: [String: Service]
    public var networks: [String: NetworkSpec?]?
    public var volumes: [String: VolumeSpec?]?
    public var configs: [String: FileObjectSpec?]?
    public var secrets: [String: FileObjectSpec?]?
    /// Other Compose files merged into this one (resolved away by `Project.load`).
    public var include: [IncludeRef]?

    /// Decode a Compose file from a YAML string.
    ///
    /// This performs decoding only — it does not interpolate `${VAR}` references
    /// or resolve `include:`/`extends:`. Use
    /// ``Project/load(explicit:projectName:cwd:envFile:profiles:)`` for the full
    /// pipeline.
    ///
    /// - Parameter yaml: the Compose YAML document.
    /// - Returns: the decoded model.
    /// - Throws: a `DecodingError` if the YAML does not match the model.
    public static func parse(yaml: String) throws -> ComposeFile {
        try YAMLDecoder().decode(ComposeFile.self, from: yaml)
    }
}

/// A single Compose service.
///
/// A pragmatic subset of the compose-spec service keys, grouped below into the
/// fields `ContainerTranslator` maps onto `container run`, the popular
/// local-development fields, and fields that are decoded so files parse but have
/// no `container` equivalent (the `Orchestrator` warns about those).
public struct Service: Decodable, Sendable {
    public var image: String?
    public var build: BuildSpec?
    public var command: StringOrList?
    public var entrypoint: StringOrList?
    public var environment: KeyValuePairs?
    public var env_file: StringOrList?
    public var ports: [PortMapping]?
    public var expose: [ComposeScalar]?
    public var volumes: [VolumeMount]?
    public var networks: NameListOrMap?
    public var depends_on: DependsOn?
    public var labels: KeyValuePairs?
    public var working_dir: String?
    public var user: String?
    public var container_name: String?
    public var restart: String?
    public var cap_add: [String]?
    public var cap_drop: [String]?
    public var dns: StringOrList?
    public var tmpfs: StringOrList?
    public var read_only: Bool?
    public var `init`: Bool?
    public var platform: String?
    public var privileged: Bool?
    public var deploy: Deploy?
    public var cpus: ComposeScalar?
    public var mem_limit: String?
    public var healthcheck: Healthcheck?

    // MARK: Popular local-development fields

    /// Service is only started when one of these profiles is active.
    public var profiles: [String]?

    // Translatable onto `container run` (see ContainerTranslator).
    public var tty: Bool?
    public var stdin_open: Bool?
    public var ulimits: Ulimits?
    public var shm_size: ComposeScalar?
    public var dns_search: StringOrList?
    public var dns_opt: [String]?
    public var runtime: String?

    // Decoded so files parse, but `container` has no equivalent flag — the
    // Orchestrator warns when these are set so the gap is visible.
    public var hostname: String?
    public var extra_hosts: ExtraHosts?
    public var network_mode: String?
    public var devices: [DeviceMapping]?
    public var sysctls: KeyValuePairs?
    public var security_opt: [String]?
    public var stop_signal: String?
    public var stop_grace_period: ComposeScalar?
    public var pull_policy: String?
    public var gpus: GPUs?

    /// References to top-level `configs:` / `secrets:`, mounted as files.
    public var configs: [ServiceFileRef]?
    public var secrets: [ServiceFileRef]?

    /// Inherit another service's config (resolved away by `Project.load`).
    public var extends: ExtendsRef?
}

/// `extends: base` or `extends: { service: base, file: other.yml }`.
public struct ExtendsRef: Decodable, Sendable, Equatable {
    public var service: String
    public var file: String?

    private enum CodingKeys: String, CodingKey { case service, file }

    public init(from decoder: Decoder) throws {
        if let c = try? decoder.singleValueContainer(), let s = try? c.decode(String.self) {
            self.service = s
            self.file = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.service = try c.decode(String.self, forKey: .service)
        self.file = try c.decodeIfPresent(String.self, forKey: .file)
    }
}

/// A top-level `include` entry: a path string, or `{ path: ... }` (path may be
/// a string or a list). `env_file`/`project_directory` are accepted but ignored.
public struct IncludeRef: Decodable, Sendable, Equatable {
    public var paths: [String]

    private enum CodingKeys: String, CodingKey { case path }

    public init(from decoder: Decoder) throws {
        if let c = try? decoder.singleValueContainer(), let s = try? c.decode(String.self) {
            self.paths = [s]
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.paths = try c.decode(StringOrList.self, forKey: .path).values
    }
}

/// A top-level `configs:` / `secrets:` definition. The two share a shape; the
/// source is one of `file`, `environment`, `content`, or `external`.
public struct FileObjectSpec: Decodable, Sendable, Equatable {
    public var file: String?
    public var environment: String?
    public var content: String?
    public var external: ExternalRef?
    public var name: String?
}

/// A service-level config/secret reference: short (`- db_password`) or long
/// (`{source, target, uid, gid, mode}`).
public enum ServiceFileRef: Decodable, Sendable, Equatable {
    case short(String)
    case long(Long)

    public struct Long: Decodable, Sendable, Equatable {
        public var source: String
        public var target: String?
        public var uid: String?
        public var gid: String?
        // Often the octal int `0444`, sometimes the string `"0444"`.
        public var mode: ComposeScalar?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .short(s)
        } else {
            self = .long(try c.decode(Long.self))
        }
    }

    /// The referenced top-level source name.
    public var source: String {
        switch self {
        case .short(let s): return s
        case .long(let l): return l.source
        }
    }
}

/// `depends_on` as a plain list, or a map of `service -> { condition }`.
public enum DependsOn: Decodable, Sendable {
    case list([String])
    case map([String: Dependency])

    public struct Dependency: Decodable, Sendable {
        public var condition: String?  // service_started | service_healthy | service_completed_successfully
        public var required: Bool?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let arr = try? c.decode([String].self) {
            self = .list(arr)
        } else {
            self = .map(try c.decode([String: Dependency].self))
        }
    }

    public var names: [String] {
        switch self {
        case .list(let a): return a
        case .map(let m): return m.keys.sorted()
        }
    }

    /// Declared start condition for a dependency (defaults to `service_started`).
    public func condition(for name: String) -> String {
        if case .map(let m) = self, let c = m[name]?.condition { return c }
        return "service_started"
    }
}

/// `build: ./dir` or a long-form build block.
public enum BuildSpec: Decodable, Sendable {
    case context(String)
    case long(LongBuild)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .context(s)
        } else {
            self = .long(try c.decode(LongBuild.self))
        }
    }

    public var contextPath: String {
        switch self {
        case .context(let s): return s
        case .long(let b): return b.context ?? "."
        }
    }

    public var dockerfile: String? {
        if case .long(let b) = self { return b.dockerfile }
        return nil
    }

    public var target: String? {
        if case .long(let b) = self { return b.target }
        return nil
    }

    public var args: KeyValuePairs? {
        if case .long(let b) = self { return b.args }
        return nil
    }

    /// The long-form block, if any (for the advanced fields below).
    public var long: LongBuild? {
        if case .long(let b) = self { return b }
        return nil
    }
}

public struct LongBuild: Decodable, Sendable {
    public var context: String?
    public var dockerfile: String?
    public var args: KeyValuePairs?
    public var target: String?

    // Advanced build fields.
    public var no_cache: Bool?
    public var labels: KeyValuePairs?
    public var secrets: [ServiceFileRef]?
    // Decoded so files parse, but `container build` has no equivalent flag.
    public var ssh: StringOrList?
    public var network: String?
    public var cache_from: [String]?
}

/// `ports` entry: `"8080:80"`, `8080`, or a long-form mapping.
public enum PortMapping: Decodable, Sendable {
    case short(String)
    case long(LongPort)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .short(s)
        } else if let i = try? c.decode(Int.self) {
            self = .short(String(i))
        } else {
            self = .long(try c.decode(LongPort.self))
        }
    }

    /// Render as a `container --publish` argument.
    public var publishArgument: String {
        switch self {
        case .short(let s):
            return s
        case .long(let p):
            var lhs = ""
            if let host = p.host_ip { lhs += "\(host):" }
            if let published = p.published { lhs += "\(published.stringValue):" }
            var arg = "\(lhs)\(p.target)"
            if let proto = p.`protocol` { arg += "/\(proto)" }
            return arg
        }
    }
}

public struct LongPort: Decodable, Sendable {
    public var target: Int
    public var published: ComposeScalar?
    public var host_ip: String?
    public var `protocol`: String?
    public var mode: String?
}

/// `volumes` entry: `"name:/path"`, `"/host:/ctr:ro"`, or a long-form mapping.
public enum VolumeMount: Decodable, Sendable {
    case short(String)
    case long(LongVolume)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .short(s)
        } else {
            self = .long(try c.decode(LongVolume.self))
        }
    }
}

public struct LongVolume: Decodable, Sendable {
    public var type: String?  // volume | bind | tmpfs
    public var source: String?
    public var target: String
    public var read_only: Bool?
}

public struct Deploy: Decodable, Sendable {
    public var resources: Resources?

    public struct Resources: Decodable, Sendable {
        public var limits: Limits?

        public struct Limits: Decodable, Sendable {
            public var cpus: ComposeScalar?
            public var memory: String?
        }
    }
}

public struct Healthcheck: Decodable, Sendable {
    public var test: StringOrList?
    public var interval: String?
    public var timeout: String?
    public var retries: Int?
    public var start_period: String?
    public var disable: Bool?
}

public struct NetworkSpec: Decodable, Sendable {
    public var driver: String?
    public var name: String?
    public var external: ExternalRef?
    public var `internal`: Bool?
    public var ipam: IPAM?

    public struct IPAM: Decodable, Sendable {
        public var config: [IPAMConfig]?

        public struct IPAMConfig: Decodable, Sendable {
            public var subnet: String?
        }
    }

    /// First declared subnet, if any.
    public var subnet: String? { ipam?.config?.first?.subnet }
}

public struct VolumeSpec: Decodable, Sendable {
    public var driver: String?
    public var name: String?
    public var external: ExternalRef?
    public var labels: KeyValuePairs?
}
