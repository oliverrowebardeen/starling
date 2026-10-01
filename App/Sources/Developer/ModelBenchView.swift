#if DEBUG
// The Developer section is in Debug builds only (ADR 0015 decision 5).
import FoundationModels
import StarlingAgent
import StarlingAgentBench
import SwiftUI

/// Runs the Phase 0 model bench on this phone and shares the report.
@MainActor
@Observable
final class BenchRunner {
    let agent = FoundationModelsAgent(estimateWhenUncountable: true)
    private(set) var isRunning = false
    private(set) var progress: [String] = []
    private(set) var report: BenchReport?
    private(set) var failure: String?

    var availability: String {
        switch SystemLanguageModel.default.availability {
        case .available: "Available"
        case .unavailable(let reason): "Unavailable: \(reason)"
        }
    }

    func run(repetitions: Int) async {
        isRunning = true
        progress = []
        report = nil
        failure = nil
        let bench = NegotiationBench(model: agent, tokensAreEstimates: !FoundationModelsAgent.canCountTokens, modelVariant: agent.variantName)
        do {
            report = try await bench.run(repetitions: repetitions) { measurement in
                let line = "\(measurement.task.rawValue) \(measurement.scenario) r\(measurement.round): \(measurement.outcome)"
                Task { @MainActor [weak self] in self?.progress.append(line) }
            }
        } catch {
            failure = String(describing: error)
        }
        isRunning = false
    }
}

struct ModelBenchView: View {
    @State private var runner = BenchRunner()
    @State private var repetitions = 3

    var body: some View {
        List {
            Section("Model") {
                LabeledContent("Availability", value: runner.availability)
                LabeledContent("Variant", value: runner.agent.variantName ?? "Unknown on this SDK")
                LabeledContent("Context size", value: "\(runner.agent.contextSize) tokens")
                LabeledContent("Token counts", value: FoundationModelsAgent.canCountTokens ? "Exact" : "Estimated")
            }

            Section {
                Stepper("Repetitions: \(repetitions)", value: $repetitions, in: 1...5)
                Button(runner.isRunning ? "Running..." : "Run bench") {
                    Task { await runner.run(repetitions: repetitions) }
                }
                .disabled(runner.isRunning)
            } footer: {
                Text("Keep the app in the foreground. The system may throttle the model in the background.")
            }

            if let report = runner.report {
                Section("Result") {
                    if let worst = report.worstCaseTokens {
                        LabeledContent("Worst call", value: "\(worst) tokens")
                    }
                    ShareLink("Share report", item: report.markdown())
                    Text(report.markdown()).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            if let failure = runner.failure {
                Section("Error") { Text(failure).foregroundStyle(.red) }
            }
            if !runner.progress.isEmpty {
                Section("Progress") {
                    ForEach(Array(runner.progress.enumerated().reversed()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
        }
        .navigationTitle("Model Bench")
    }
}
#endif
