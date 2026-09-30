import Foundation
import StarlingAgent
import StarlingAgentBench

// Runs the Phase 0 model bench with the on-device model on this Mac.
// Usage: swift run agent-bench [--repetitions N] [--json path]

var repetitions = 1
var jsonPath: String?
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    switch flag {
    case "--repetitions": repetitions = arguments.isEmpty ? 1 : Int(arguments.removeFirst()) ?? 1
    case "--json": jsonPath = arguments.isEmpty ? nil : arguments.removeFirst()
    default:
        print("usage: agent-bench [--repetitions N] [--json path]")
        exit(1)
    }
}

let agent = FoundationModelsAgent(estimateWhenUncountable: true)
let bench = NegotiationBench(
    model: agent,
    tokensAreEstimates: !FoundationModelsAgent.canCountTokens,
    modelVariant: agent.variantName
)
FileHandle.standardError.write(Data("Running \(repetitions) repetition(s) on \(agent.descriptor.identifier)...\n".utf8))
let report = try await bench.run(repetitions: repetitions) { measurement in
    FileHandle.standardError.write(Data("  \(measurement.task.rawValue) \(measurement.scenario) r\(measurement.round): \(measurement.outcome)\n".utf8))
}
print(report.markdown())
if let jsonPath {
    try report.json().write(to: URL(fileURLWithPath: jsonPath))
}
