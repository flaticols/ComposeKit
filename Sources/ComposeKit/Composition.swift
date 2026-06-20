import Foundation

// Resolves `include:` and `extends:` into a single flat ComposeFile, reading and
// interpolating referenced files. Run by Project.load before the model is used.
enum Composition {
    /// Load and interpolate a Compose file from disk.
    static func load(_ url: URL, variables: [String: String]) throws -> ComposeFile {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw ComposeError.fileNotFound([url.path])
        }
        return try ComposeFile.parse(yaml: Interpolator.expand(raw, variables: variables))
    }

    /// Merge any `include:` files under `file` (the including file wins). Nested
    /// includes are resolved depth-first.
    static func resolveIncludes(
        _ file: ComposeFile, baseDir: URL, variables: [String: String]
    ) throws -> ComposeFile {
        guard let includes = file.include, !includes.isEmpty else { return file }
        var base: ComposeFile?
        for inc in includes {
            for path in inc.paths {
                let url = URL(fileURLWithPath: path, relativeTo: baseDir).standardizedFileURL
                var included = try load(url, variables: variables)
                included = try resolveIncludes(
                    included, baseDir: url.deletingLastPathComponent(), variables: variables)
                base = base.map { included.merged(onto: $0) } ?? included
            }
        }
        guard let base else { return file }
        var result = file.merged(onto: base)
        result.include = nil
        return result
    }

    /// Resolve service-level `extends:` (same file or another file), merging the
    /// base service under the deriving one. Detects cycles.
    static func resolveExtends(
        _ file: ComposeFile, baseDir: URL, variables: [String: String]
    ) throws -> ComposeFile {
        guard file.services.values.contains(where: { $0.extends != nil }) else { return file }

        var fileCache: [String: (file: ComposeFile, dir: URL)] = [:]
        var resolved: [String: Service] = [:]

        func entry(for url: URL) throws -> (file: ComposeFile, dir: URL) {
            if let e = fileCache[url.path] { return e }
            let e = (file: try load(url, variables: variables), dir: url.deletingLastPathComponent())
            fileCache[url.path] = e
            return e
        }

        func resolveService(
            _ name: String, in f: ComposeFile, fileKey: String, dir: URL, stack: [String]
        ) throws -> Service {
            let key = "\(fileKey)#\(name)"
            if let r = resolved[key] { return r }
            if stack.contains(key) { throw ComposeError.extendsCycle(name) }
            guard var svc = f.services[name] else { throw ComposeError.unknownService(name) }
            if let ext = svc.extends {
                let baseSvc: Service
                if let extPath = ext.file {
                    let url = URL(fileURLWithPath: extPath, relativeTo: dir).standardizedFileURL
                    let e = try entry(for: url)
                    baseSvc = try resolveService(
                        ext.service, in: e.file, fileKey: url.path, dir: e.dir, stack: stack + [key])
                } else {
                    baseSvc = try resolveService(
                        ext.service, in: f, fileKey: fileKey, dir: dir, stack: stack + [key])
                }
                svc = svc.merged(onto: baseSvc)
            }
            resolved[key] = svc
            return svc
        }

        var out = file
        for name in file.services.keys {
            out.services[name] = try resolveService(
                name, in: file, fileKey: "<main>", dir: baseDir, stack: [])
        }
        return out
    }
}
