import StarlingCore
import StarlingFeatures
import SwiftUI

/// Phase 0 tools and, in Debug builds, controls that drive the fakes so the
/// whole journey can be walked before lanes E1, E2, F, and G merge.
struct DeveloperView: View {
    let app: AppModel
    #if DEBUG
    let harness: DebugHarness
    @AppStorage(DebugHarness.scriptedModelKey) private var scriptedModel = false
    @State private var status: String?
    #endif
    @AppStorage(RootView<EmptyView>.onboardingKey) private var onboardingFinished = false

    var body: some View {
        List {
            Section {
                NavigationLink("Model Bench", destination: ModelBenchView())
                #if DEBUG
                NavigationLink("Nearby", destination: NearbyView())
                #endif
            } header: {
                Text("Phase 0 spike")
            } footer: {
                #if DEBUG
                Text("Nearby links are not encrypted, so don't send anything personal. Nearby is left out of Release builds.")
                #endif
            }

            #if DEBUG
            fakes
            #endif

            Section {
                NavigationLink("Audit log") { AuditLogView(log: LiveServices.auditLog, friends: app.friends?.friends ?? []) }
            } footer: {
                Text("What this phone handed to a transport since launch.")
            }

            Section("Build") {
                LabeledContent("Services", value: buildKind)
                Button("Show onboarding again") { onboardingFinished = false }
            }
        }
        .navigationTitle("Developer")
    }

    private var buildKind: String {
        #if DEBUG
        "Debug (fakes for unmerged lanes)"
        #else
        "Release (no fakes)"
        #endif
    }

    #if DEBUG
    @ViewBuilder private var fakes: some View {
        Section {
            Button("Add a sample friend") {
                Task {
                    await harness.addSampleFriend()
                    await app.friends?.load()
                    status = "Added a friend."
                }
            }
            Button("Simulate: checking with friends") { Task { await harness.simulateChecking() } }
            Button("Simulate: match (both down)") { Task { await simulateMatch(bothDown: true) } }
            Button("Simulate: match (a maybe)") { Task { await simulateMatch(bothDown: false) } }
            Button("Simulate: Down? expired") { harness.simulateEnded(.expired) }
            Button("Simulate: Down? failed") { harness.simulateEnded(.failed) }
            Button("Send a sample through Outbox") {
                Task { status = await harness.sendSample(through: app.outbox) }
            }
            Button("Send, with the policy changing during consent") {
                Task { status = await harness.sendWithPolicyChangingDuringConsent(through: app.consent) }
            }
            Button("Simulate: message from a friend") {
                Task { status = await harness.simulateInboundMessage() }
            }
            Toggle("Scripted model (next launch)", isOn: $scriptedModel)
            if let status { Text(status).foregroundStyle(.secondary) }
        } header: {
            Text("Fakes (Debug builds only)")
        } footer: {
            Text("Stands in for lanes E1 and F until they merge. Sends go through the app's Outbox (lane G's policy and audit log) and are recorded, not delivered. An approved sample is not asked again for 10 minutes or until the Down? intent changes. The scripted model returns the same rules every time, including \"karaoke\", so the review flags show.")
        }
    }

    private func simulateMatch(bothDown: Bool) async {
        status = await harness.simulateMatch(bothDown: bothDown) ? "Sent a match event." : "Add a friend first."
    }
    #endif
}
