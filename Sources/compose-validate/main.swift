// compose-validate — check that a Compose file parses via ComposeKit.
//
// A tiny CLI used both by humans and by the CI parity job to answer one question
// without standing up a full frontend:
//
//   compose-validate <file>...            # does ComposeKit accept this file?
//   compose-validate --profile dev <file> # report services active for a profile
//
// Exit code is 0 only if every file parsed; non-zero if any failed.

import ComposeKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("compose-validate: \(message)\n".utf8))
    exit(2)
}

var files: [String] = []
var profiles: [String] = []

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let arg = args[i]
    switch arg {
    case "--profile":
        i += 1
        guard i < args.count else { fail("--profile needs a value") }
        profiles.append(contentsOf: args[i].split(separator: ",").map(String.init))
    case "-h", "--help":
        print(
            """
            usage: compose-validate [--profile NAME]... <file>...

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
        let skipped = project.file.services.count - enabled.count
        let suffix = skipped > 0 ? " (\(skipped) inactive by profile)" : ""
        print("OK \(path): \(order.count) service(s)\(suffix)")
    } catch {
        FileHandle.standardError.write(Data("FAIL \(path): \(error)\n".utf8))
        failed = true
    }
}

exit(failed ? 1 : 0)
