// compose-bench — lightweight, dependency-free micro-benchmarks.
//
// SwiftPM has no first-class benchmark harness and swift-testing has no
// `measure`, so rather than pull a heavy dependency (e.g. ordo-one/
// package-benchmark, which needs a jemalloc system library) we time release-mode
// loops with ContinuousClock. The inputs are small and the goal is relative,
// not absolute, numbers — enough to catch a regression in a hot path.
//
// Run with:  swift run -c release compose-bench   (debug numbers are meaningless)

import ComposeKit
import ComposeKitContainer
import Foundation

// Accumulator that consumes each result so the optimizer can't elide the work.
nonisolated(unsafe) var blackHole = 0

func bench(_ name: String, iterations: Int = 50_000, _ body: () throws -> Int) {
    do {
        for _ in 0..<500 { blackHole &+= try body() }  // warm up
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<iterations { blackHole &+= try body() }
        let elapsed = start.duration(to: clock.now)
        let ns =
            Double(elapsed.components.seconds) * 1e9
            + Double(elapsed.components.attoseconds) / 1e9
        let perOp = ns / Double(iterations)
        let label = name.padding(toLength: 30, withPad: " ", startingAt: 0)
        print("\(label) \(String(format: "%8.0f", perOp)) ns/op   (\(iterations) iters)")
    } catch {
        print("\(name): FAILED — \(error)")
    }
}

let yaml = """
    name: bench
    services:
      db:
        image: postgres:16
        environment:
          POSTGRES_USER: ${USER:-app}
          POSTGRES_PASSWORD: secret
        volumes:
          - dbdata:/var/lib/postgresql/data
        healthcheck:
          test: ["CMD-SHELL", "pg_isready"]
          interval: 5s
      web:
        image: web:${TAG:-latest}
        command: ["node", "server.js"]
        ports:
          - "8080:80"
          - "127.0.0.1:9090:9090/tcp"
        environment:
          - DATABASE_URL=postgres://app@db:5432/app
        depends_on:
          db:
            condition: service_healthy
        ulimits:
          nofile:
            soft: 1024
            hard: 524288
        deploy:
          resources:
            limits:
              cpus: "0.5"
              memory: 256m
        networks: [backend, frontend]
    networks:
      backend:
      frontend:
    volumes:
      dbdata:
    """

let vars = ["TAG": "1.2.3", "USER": "app"]

bench("Interpolator.expand") { try Interpolator.expand(yaml, variables: vars).count }
bench("ComposeFile.parse") { try ComposeFile.parse(yaml: yaml).services.count }
bench("expand + parse (pipeline)") {
    try ComposeFile.parse(yaml: Interpolator.expand(yaml, variables: vars)).services.count
}

let file = try ComposeFile.parse(yaml: yaml)
let translator = ContainerTranslator(
    project: "bench", baseDirectory: URL(fileURLWithPath: "/proj"), hostEnv: vars)
let web = file.services["web"]!
bench("ContainerTranslator.runArgs") {
    translator.runArgs(service: "web", web, image: "web:1.2.3").count
}

// Keep the accumulator observably alive.
if blackHole == Int.min { print(blackHole) }
