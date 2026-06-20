/// Computes service start order from `depends_on`.
///
/// This resolves *ordering* only. The `depends_on` *conditions*
/// (`service_healthy`, `service_completed_successfully`) are enforced separately
/// by the container layer's `Orchestrator` during `up`.
public enum Planner {
    /// Return service names in dependency order (dependencies first).
    ///
    /// - Parameter services: the project's services, keyed by name.
    /// - Returns: a topological ordering where every service appears after the
    ///   services it depends on. Sorted for deterministic output.
    /// - Throws: ``ComposeError/dependencyCycle(_:)`` if `depends_on` is cyclic.
    public static func startOrder(_ services: [String: Service]) throws -> [String] {
        var visited = Set<String>()
        var inProgress = Set<String>()
        var order: [String] = []

        func visit(_ name: String) throws {
            if visited.contains(name) { return }
            if inProgress.contains(name) { throw ComposeError.dependencyCycle(name) }
            inProgress.insert(name)
            let deps = services[name]?.depends_on?.names ?? []
            for dep in deps where services[dep] != nil {
                try visit(dep)
            }
            inProgress.remove(name)
            visited.insert(name)
            order.append(name)
        }

        for name in services.keys.sorted() {
            try visit(name)
        }
        return order
    }
}
