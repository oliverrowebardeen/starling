import Foundation
import Scenarios

// Usage: swift run starling-sim [scenario|all] [--agents N]

let arguments = Array(CommandLine.arguments.dropFirst())
var agents = 3
var names: [String] = []
var index = 0
while index < arguments.count {
    if arguments[index] == "--agents", index + 1 < arguments.count, let count = Int(arguments[index + 1]), count >= 2 {
        agents = count
        index += 2
    } else {
        names.append(arguments[index])
        index += 1
    }
}

if names.isEmpty || names.contains("--help") {
    print("usage: starling-sim [scenario|all] [--agents N]\n")
    for scenario in Scenario.allCases { print("  \(scenario.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \(scenario.summary)") }
    exit(names.isEmpty ? 1 : 0)
}

let selected: [Scenario]
if names == ["all"] {
    selected = Scenario.allCases
} else {
    selected = names.compactMap(Scenario.init(rawValue:))
    guard selected.count == names.count else {
        print("unknown scenario in \(names); run with --help")
        exit(1)
    }
}

for scenario in selected {
    print("=== \(scenario.rawValue): \(scenario.summary)")
    do {
        let outcome = try await ScenarioRunner.run(scenario, agents: agents)
        for line in outcome.transcript { print("  \(line)") }
        print("  target accepted \(outcome.accepted.count), dropped \(outcome.dropped.count)\n")
    } catch {
        print("  FAILED: \(error)\n")
        exit(1)
    }
}
