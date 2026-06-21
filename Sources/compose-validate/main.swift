// compose-validate — parse (and optionally plan) a Compose file via ComposeKit.
//
// A tiny, dependency-free CLI used both by humans and by the CI parity job to
// answer two questions without standing up a full frontend:
//
//   compose-validate <file>...            # does ComposeKit accept this file?
//   compose-validate --plan <file>        # what `container` argv would it emit?
//   compose-validate --profile dev <file> # with profiles active
//
// Exit code is 0 only if every file parsed; non-zero if any failed.

import ComposeKit
import ComposeKitContainer
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("compose-validate: \(message)\n".utf8))
    exit(2)
}

var files: [String] = []
var profiles: [String] = []
var plan = false

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let arg = args[i]
    switch arg {
    case "--plan":
        plan = true
    case "--profile":
        i += 1
        guard i < args.count else { fail("--profile needs a value") }
        profiles.append(contentsOf: args[i].split(separator: ",").map(String.init))
    case "-h", "--help":
        print(
            """
            usage: compose-validate [--plan] [--profile NAME]... <file>...

              --plan            print resolved start order and the `container`
                                argv each service would run
              --profile NAME    activate a profile (comma-separated or repeated)

            Exit status is 0 only if every file parses.
            """)
        exit(0)
    default:
        if arg.hasPrefix("-") { fail("unknown option: \(arg)") }
        files.append(arg)
    }
    i += 1
}

guard !files.isEmpty else { fail("no compose file given (see --help)") }

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
var failed = false

for path in files {
    do {
        let project = try Project.load(
            explicit: path, projectName: nil, cwd: cwd, profiles: profiles)
        let enabled = project.enabledServices()
        let order = try Planner.startOrder(project.file.services).filter { enabled.contains($0) }

        if plan {
            print("\(path): project '\(project.name)'")
            let translator = ContainerTranslator(
                project: project.name,
                baseDirectory: project.baseDirectory,
                hostEnv: project.variables)
            for name in order {
                guard let svc = project.file.services[name] else { continue }
                let image = svc.image ?? translator.builtImageTag(service: name)
                let argv = translator.runArgs(service: name, svc, image: image)
                print("  \(name): container \(argv.joined(separator: " "))")
            }
        } else {
            let skipped = project.file.services.count - enabled.count
            let suffix = skipped > 0 ? " (\(skipped) inactive by profile)" : ""
            print("OK \(path): \(order.count) service(s)\(suffix)")
        }
    } catch {
        FileHandle.standardError.write(Data("FAIL \(path): \(error)\n".utf8))
        failed = true
    }
}

exit(failed ? 1 : 0)
