import Foundation
import StarlingAgent
import StarlingAgentBench

// Runs the model bench with the on-device model on this Mac.
// Usage: swift run agent-bench [--repetitions N] [--json path]
//        swift run agent-bench --interpretation [--held-out] [--json path]
// The second form scores the labeled interpretation set (or the held-out
// set) instead.

var repetitions = 1
var jsonPath: String?
var interpretation = false
var heldOut = false
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    switch flag {
    case "--repetitions": repetitions = arguments.isEmpty ? 1 : Int(arguments.removeFirst()) ?? 1
    case "--json": jsonPath = arguments.isEmpty ? nil : arguments.removeFirst()
    case "--interpretation": interpretation = true
    case "--held-out": heldOut = true
    default:
        print("usage: agent-bench [--repetitions N] [--json path] | agent-bench --interpretation [--held-out] [--json path]")
        exit(1)
    }
}

if interpretation {
    let agent = FoundationModelsAgent(timeZone: InterpretationSet.timeZone)
    let labels = heldOut ? InterpretationSet.heldOut : InterpretationSet.labels
    FileHandle.standardError.write(Data("Scoring \(labels.count) utterances on \(agent.descriptor.identifier)...\n".utf8))
    let report = await InterpretationEval(model: agent, labels: labels).run { result in
        FileHandle.standardError.write(Data("  \(result.isExact ? "ok  " : "miss") \(result.label.text)\n".utf8))
    }
    print(report.markdown(title: heldOut ? "Interpretation accuracy, held-out set" : "Interpretation accuracy"))
    if let jsonPath {
        try report.json().write(to: URL(fileURLWithPath: jsonPath))
    }
    exit(0)
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
