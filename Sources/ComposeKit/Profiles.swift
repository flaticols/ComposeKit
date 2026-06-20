/// Decides which services are "enabled" for a run, following Compose
/// [profile](https://docs.docker.com/compose/how-tos/profiles/) rules:
///
/// - A service with no `profiles:` is always enabled.
/// - A service with `profiles:` is enabled only when one of its profiles is
///   active (via `COMPOSE_PROFILES` or `--profile`).
/// - Naming a service explicitly enables it even if its profile is inactive, and
///   activates that service's own profiles.
/// - Dependencies (`depends_on`) of an enabled service are pulled in even when
///   their own profile is inactive.
///
/// ``Project/enabledServices(explicit:)`` is the usual entry point.
public enum Profiles {
    /// Resolve the set of services to operate on.
    ///
    /// - Parameters:
    ///   - services: all services in the project.
    ///   - active: profiles activated out-of-band (COMPOSE_PROFILES / `--profile`).
    ///   - explicit: services named on the command line (empty = "all enabled").
    public static func enabled(
        services: [String: Service],
        active: Set<String>,
        explicit: [String] = []
    ) -> Set<String> {
        // Explicitly named services also activate their own profiles.
        var activeProfiles = active
        for name in explicit {
            for p in services[name]?.profiles ?? [] { activeProfiles.insert(p) }
        }

        func matchesActiveProfile(_ name: String) -> Bool {
            let p = services[name]?.profiles ?? []
            return p.isEmpty || !Set(p).isDisjoint(with: activeProfiles)
        }

        // Seed set: explicit selection, else every profile-active service.
        var enabled: Set<String>
        if explicit.isEmpty {
            enabled = Set(services.keys.filter(matchesActiveProfile))
        } else {
            enabled = Set(explicit.filter { services[$0] != nil })
        }

        // Pull in dependencies transitively, regardless of their profile.
        var queue = Array(enabled)
        while let name = queue.popLast() {
            for dep in services[name]?.depends_on?.names ?? [] where services[dep] != nil {
                if enabled.insert(dep).inserted { queue.append(dep) }
            }
        }
        return enabled
    }
}
