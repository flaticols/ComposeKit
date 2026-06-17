//===----------------------------------------------------------------------===//
// Polymorphic decoding helpers for the Compose spec.
//
// The Compose file format is loose: many fields accept either a scalar, a
// sequence, or a mapping. These small wrappers normalize those shapes so the
// rest of the code can treat them uniformly.
//===----------------------------------------------------------------------===//

import Foundation

/// A YAML scalar that may appear as a string, integer, double, or bool.
/// Normalized to its string form (e.g. `0.5`, `true`, `8080`).
public struct ComposeScalar: Decodable, Sendable, Equatable {
    public let stringValue: String

    public init(_ value: String) { self.stringValue = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self.stringValue = ""
        } else if let s = try? c.decode(String.self) {
            self.stringValue = s
        } else if let b = try? c.decode(Bool.self) {
            self.stringValue = b ? "true" : "false"
        } else if let i = try? c.decode(Int.self) {
            self.stringValue = String(i)
        } else if let d = try? c.decode(Double.self) {
            self.stringValue = String(d)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported scalar value")
        }
    }
}

/// A field that is either a single string or a list of strings
/// (e.g. `command`, `entrypoint`, `dns`, `env_file`).
public enum StringOrList: Decodable, Sendable, Equatable {
    case string(String)
    case list([String])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let arr = try? c.decode([String].self) {
            self = .list(arr)
        } else {
            self = .string(try c.decode(String.self))
        }
    }

    /// Flattened list form. A single string becomes a one-element list.
    public var values: [String] {
        switch self {
        case .string(let s): return [s]
        case .list(let a): return a
        }
    }
}

/// A `key=value` collection that is either a mapping or a `KEY=VALUE` list
/// (e.g. `environment`, `labels`, `build.args`).
public enum KeyValuePairs: Decodable, Sendable, Equatable {
    case map([String: ComposeScalar?])
    case list([String])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let arr = try? c.decode([String].self) {
            self = .list(arr)
        } else {
            self = .map(try c.decode([String: ComposeScalar?].self))
        }
    }

    /// Resolve to `KEY=VALUE` strings. Entries with no value are filled from
    /// `hostEnv` (Compose's variable pass-through), or dropped if absent.
    public func pairs(hostEnv: [String: String] = [:]) -> [String] {
        switch self {
        case .list(let arr):
            return arr.compactMap { item in
                if item.contains("=") { return item }
                if let v = hostEnv[item] { return "\(item)=\(v)" }
                return nil
            }
        case .map(let dict):
            return dict.sorted { $0.key < $1.key }.compactMap { key, value in
                if let value, !value.stringValue.isEmpty {
                    return "\(key)=\(value.stringValue)"
                }
                if let v = hostEnv[key] { return "\(key)=\(v)" }
                return nil
            }
        }
    }
}

/// A name->config mapping or a plain list of names (e.g. `depends_on`,
/// service-level `networks`). We only need the set of names for orchestration.
public enum NameListOrMap: Decodable, Sendable, Equatable {
    case list([String])
    case map([String: AnyConfig])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let arr = try? c.decode([String].self) {
            self = .list(arr)
        } else {
            self = .map(try c.decode([String: AnyConfig].self))
        }
    }

    public var names: [String] {
        switch self {
        case .list(let a): return a
        case .map(let m): return m.keys.sorted()
        }
    }
}

/// Opaque, ignored sub-config. Lets us accept (and skip) the body of
/// `depends_on: {db: {condition: ...}}` or `networks: {net: {aliases: ...}}`
/// without modelling every nested field yet.
public struct AnyConfig: Decodable, Sendable, Equatable {
    public init(from decoder: Decoder) throws {}
}

/// `ulimits` entry: either a single hard limit (`nofile: 65535`) or a
/// `{soft, hard}` pair. Rendered as `name=value` or `name=soft:hard`.
public enum ULimitValue: Decodable, Sendable, Equatable {
    case single(String)
    case range(soft: String, hard: String)

    private enum CodingKeys: String, CodingKey { case soft, hard }

    public init(from decoder: Decoder) throws {
        // The spec allows integer OR string for each limit, so normalize via
        // ComposeScalar rather than insisting on Int (docker accepts both).
        if let c = try? decoder.singleValueContainer(), let s = try? c.decode(ComposeScalar.self) {
            self = .single(s.stringValue)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = .range(
            soft: try c.decode(ComposeScalar.self, forKey: .soft).stringValue,
            hard: try c.decode(ComposeScalar.self, forKey: .hard).stringValue)
    }

    /// The value part of a `--ulimit name=...` argument.
    public var argumentValue: String {
        switch self {
        case .single(let v): return v
        case .range(let soft, let hard): return "\(soft):\(hard)"
        }
    }
}

/// `ulimits: { nofile: 65535, nproc: {soft: 1024, hard: 2048} }`.
public struct Ulimits: Decodable, Sendable, Equatable {
    public let limits: [String: ULimitValue]

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.limits = try c.decode([String: ULimitValue].self)
    }

    /// `--ulimit` argument values, sorted for determinism.
    public var arguments: [String] {
        limits.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.argumentValue)" }
    }
}

/// `devices` entry: `"/dev/x:/dev/y"` or a long-form `{source, target, ...}`.
/// Decoded permissively (the long form's fields are not modeled) so spec-valid
/// files parse — `container` has no `--device`, so it is warned, not applied.
public enum DeviceMapping: Decodable, Sendable, Equatable {
    case short(String)
    case long(AnyConfig)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .short(s)
        } else {
            self = .long(try c.decode(AnyConfig.self))
        }
    }
}

/// `extra_hosts` as a list (`["host:ip"]`) or a map (`{host: ip}`).
public enum ExtraHosts: Decodable, Sendable, Equatable {
    case list([String])
    case map([String: ComposeScalar])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let arr = try? c.decode([String].self) {
            self = .list(arr)
        } else {
            self = .map(try c.decode([String: ComposeScalar].self))
        }
    }

    /// Normalized `host:ip` entries.
    public var entries: [String] {
        switch self {
        case .list(let a): return a
        case .map(let m): return m.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.stringValue)" }
        }
    }
}

/// `gpus: all`, `gpus: 1`, or `gpus: [{driver: nvidia, ...}]`. Decoded so files
/// parse; `container` has no GPU passthrough flag, so it is warned, not applied.
public enum GPUs: Decodable, Sendable, Equatable {
    case scalar(String)
    case list([AnyConfig])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let arr = try? c.decode([AnyConfig].self) {
            self = .list(arr)
        } else {
            self = .scalar(try c.decode(ComposeScalar.self).stringValue)
        }
    }
}

/// `external: true` or `external: { name: foo }`.
public struct ExternalRef: Decodable, Sendable, Equatable {
    public let isExternal: Bool
    public let name: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) {
            self.isExternal = b
            self.name = nil
        } else if let obj = try? c.decode([String: String].self) {
            self.isExternal = true
            self.name = obj["name"]
        } else {
            self.isExternal = false
            self.name = nil
        }
    }
}
