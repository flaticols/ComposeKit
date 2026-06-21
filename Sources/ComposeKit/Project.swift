import Foundation
import Yams

/// Errors raised while locating, loading, resolving, or orchestrating a project.
///
/// Conforms to `CustomStringConvertible`, so a frontend can surface
/// `String(describing:)` directly to the user.
public enum ComposeError: Error, CustomStringConvertible {
    case fileNotFound([String])
    case dependencyCycle(String)
    case serviceMissingImage(String)
    case unknownService(String)
    case interpolation(String)
    case requiredVariable(String, String?)
    case envFileNotFound(String)
    case dependencyUnhealthy(String)
    case dependencyFailed(String, Int32)
    case extendsCycle(String)

    public var description: String {
        switch self {
        case .fileNotFound(let tried):
            return "no Compose file found (looked for: \(tried.joined(separator: ", ")))"
        case .dependencyCycle(let name):
            return "dependency cycle detected involving service '\(name)'"
        case .serviceMissingImage(let name):
            return "service '\(name)' has neither 'image' nor 'build'"
        case .unknownService(let name):
            return "no such service: '\(name)'"
        case .interpolation(let message):
            return "interpolation error: \(message)"
        case .requiredVariable(let name, let message):
            let detail = if let message, !message.isEmpty { ": \(message)" } else { "" }
            return "required variable '\(name)' is not set\(detail)"
        case .envFileNotFound(let path):
            return "env file not found: \(path)"
        case .dependencyUnhealthy(let name):
            return "dependency '\(name)' did not become healthy in time"
        case .dependencyFailed(let name, let status):
            return "dependency '\(name)' did not complete successfully (exit \(status))"
        case .extendsCycle(let name):
            return "extends cycle detected involving service '\(name)'"
        }
    }
}

/// A fully resolved Compose project: the decoded ``ComposeFile`` plus the
/// project name, base directory, interpolation variables, and active profiles.
///
/// Produce one with ``load(explicit:projectName:cwd:envFile:profiles:)``, which
/// locates the file, interpolates `${VAR}` references, flattens `include:` and
/// `extends:`, and resolves the project name and active profiles. The result is
/// `Sendable` and ready to hand to ``Planner`` or, in the container layer,
/// `Orchestrator`.
public struct Project: Sendable {
    /// The resolved project name (sanitized; scopes all container/network/volume names).
    public let name: String
    /// The decoded, composition-flattened Compose model.
    public let file: ComposeFile
    /// Directory of the Compose file — relative paths resolve against this.
    public let baseDirectory: URL
    /// Variables used for `${VAR}` interpolation and `environment:` pass-through
    /// (`.env` merged with the shell environment, shell winning).
    public let variables: [String: String]
    /// Profiles activated for this run (`--profile` flags plus COMPOSE_PROFILES).
    public let activeProfiles: Set<String>

    public init(
        name: String,
        file: ComposeFile,
        baseDirectory: URL,
        variables: [String: String],
        activeProfiles: Set<String> = []
    ) {
        self.name = name
        self.file = file
        self.baseDirectory = baseDirectory
        self.variables = variables
        self.activeProfiles = activeProfiles
    }

    /// Services to operate on, honoring profile activation. Pass services named
    /// on the command line as `explicit` (empty means "all enabled").
    public func enabledServices(explicit: [String] = []) -> Set<String> {
        Profiles.enabled(services: file.services, active: activeProfiles, explicit: explicit)
    }

    public static let candidateFilenames = [
        "compose.yaml", "compose.yml",
        "docker-compose.yaml", "docker-compose.yml",
    ]

    /// Locate a Compose file: the explicit `-f` path, else the first candidate
    /// found walking up from `cwd`.
    public static func locate(explicit: String?, cwd: URL) throws -> URL {
        if let explicit {
            let url = URL(fileURLWithPath: explicit, relativeTo: cwd).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ComposeError.fileNotFound([explicit])
            }
            return url
        }
        var dir = cwd.standardizedFileURL
        while true {
            for candidate in candidateFilenames {
                let url = dir.appendingPathComponent(candidate)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }  // reached filesystem root
            dir = parent
        }
        throw ComposeError.fileNotFound(candidateFilenames)
    }

    /// Locate, load, and fully resolve a Compose project.
    ///
    /// The pipeline: locate the file, merge `.env` with the shell environment,
    /// interpolate `${VAR}` references on the raw text, decode the model, flatten
    /// `include:` then `extends:`, and resolve the project name and active
    /// profiles.
    ///
    /// - Parameters:
    ///   - explicit: an explicit file path (like `-f`); when `nil`, the first
    ///     candidate found walking up from `cwd` is used.
    ///   - projectName: overrides the project name (like `-p`); otherwise the
    ///     top-level `name:` or the parent directory name is used.
    ///   - cwd: the directory to resolve relative paths and search from.
    ///   - envFile: an explicit env file (like `--env-file`); otherwise `.env`
    ///     next to the Compose file is used if present.
    ///   - profiles: profiles to activate, merged with `COMPOSE_PROFILES`.
    /// - Returns: the resolved ``Project``.
    /// - Throws: ``ComposeError`` (file not found, interpolation, extends cycle,
    ///   missing env file) or a `DecodingError`.
    public static func load(
        explicit: String?,
        projectName: String?,
        cwd: URL,
        envFile: String? = nil,
        profiles: [String] = []
    ) throws -> Project {
        try load(
            files: explicit.map { [$0] } ?? [],
            projectName: projectName, cwd: cwd, envFile: envFile, profiles: profiles)
    }

    /// Override files auto-loaded (in this priority) next to the primary file
    /// when no explicit `-f` files are given.
    static let overrideFilenames = [
        "compose.override.yaml", "compose.override.yml",
        "docker-compose.override.yaml", "docker-compose.override.yml",
    ]

    /// Locate, load, and fully resolve a project from one or more Compose files.
    ///
    /// With no `files`, the primary file is discovered by walking up from `cwd`
    /// and a sibling `compose.override.yaml` (if present) is merged on top —
    /// matching Docker Compose. With explicit `files`, they are merged in order
    /// (later wins) and no override is auto-loaded; the first file's directory is
    /// the project directory. Each file is interpolated and has `include:` /
    /// `extends:` flattened before merging.
    ///
    /// - Parameters:
    ///   - files: explicit Compose file paths (like repeated `-f`); empty =
    ///     auto-discover + auto-override.
    ///   - projectName: overrides the project name (like `-p`).
    ///   - cwd: directory to resolve relative paths and search from.
    ///   - envFile: explicit env file (like `--env-file`); else `.env` if present.
    ///   - profiles: profiles to activate, merged with `COMPOSE_PROFILES`.
    public static func load(
        files: [String],
        projectName: String?,
        cwd: URL,
        envFile: String? = nil,
        profiles: [String] = []
    ) throws -> Project {
        let urls = try resolveFileList(files, cwd: cwd)
        let base = urls[0].deletingLastPathComponent()
        let variables = try loadVariables(envFile: envFile, baseDirectory: base, cwd: cwd)

        var merged: ComposeFile?
        for url in urls {
            let raw = try String(contentsOf: url, encoding: .utf8)
            var file = try ComposeFile.parse(yaml: Interpolator.expand(raw, variables: variables))
            let dir = url.deletingLastPathComponent()
            // Flatten composition per file: includes first, then extends.
            file = try Composition.resolveIncludes(file, baseDir: dir, variables: variables)
            file = try Composition.resolveExtends(file, baseDir: dir, variables: variables)
            merged = merged.map { file.merged(onto: $0) } ?? file
        }
        guard let file = merged else { throw ComposeError.fileNotFound(candidateFilenames) }

        let name = resolveName(override: projectName, file: file, composeURL: urls[0])
        let active = resolveProfiles(flags: profiles, variables: variables)
        return Project(
            name: name, file: file, baseDirectory: base,
            variables: variables, activeProfiles: active)
    }

    /// Expand the `-f` list into URLs. Empty list = discover the primary file and
    /// append a sibling override file if one exists.
    static func resolveFileList(_ files: [String], cwd: URL) throws -> [URL] {
        guard files.isEmpty else {
            return try files.map { try locate(explicit: $0, cwd: cwd) }
        }
        let primary = try locate(explicit: nil, cwd: cwd)
        var urls = [primary]
        let dir = primary.deletingLastPathComponent()
        for name in overrideFilenames {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                urls.append(url)
                break
            }
        }
        return urls
    }

    /// Active profiles: `--profile` flags plus a comma-separated COMPOSE_PROFILES.
    static func resolveProfiles(flags: [String], variables: [String: String]) -> Set<String> {
        var set = Set(flags)
        if let env = variables["COMPOSE_PROFILES"] {
            for p in env.split(separator: ",") {
                let trimmed = p.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { set.insert(trimmed) }
            }
        }
        return set
    }

    /// `.env` (next to the Compose file, or the explicit `--env-file`) merged
    /// with the shell environment. The shell environment takes precedence.
    static func loadVariables(envFile: String?, baseDirectory: URL, cwd: URL) throws -> [String: String] {
        var variables: [String: String] = [:]
        if let envFile {
            let path = URL(fileURLWithPath: envFile, relativeTo: cwd).standardizedFileURL
            guard let contents = try? String(contentsOf: path, encoding: .utf8) else {
                throw ComposeError.envFileNotFound(path.path)
            }
            variables = EnvFile.parse(contents)
        } else {
            let defaultEnv = baseDirectory.appendingPathComponent(".env")
            if let contents = try? String(contentsOf: defaultEnv, encoding: .utf8) {
                variables = EnvFile.parse(contents)
            }
        }
        for (key, value) in ProcessInfo.processInfo.environment {
            variables[key] = value
        }
        return variables
    }

    /// Project name precedence: `-p` flag > top-level `name:` > parent dir name.
    static func resolveName(override: String?, file: ComposeFile, composeURL: URL) -> String {
        if let override { return sanitize(override) }
        if let n = file.name { return sanitize(n) }
        return sanitize(composeURL.deletingLastPathComponent().lastPathComponent)
    }

    /// Lowercase; keep [a-z0-9_-]; collapse other runs to a single '-'.
    static func sanitize(_ raw: String) -> String {
        var out = ""
        var lastDash = false
        for ch in raw.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "compose" : trimmed
    }
}
