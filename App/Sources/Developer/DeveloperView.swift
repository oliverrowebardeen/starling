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
                NavigationLink("Wi-Fi Aware") { WiFiAwareView(app: app) }
            } footer: {
                Text("Pair two phones and test the link (lane E2's device checklist).")
            }

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
            LabeledContent("Sim friend", value: harness.simFriend.state)
            Button("Sim friend: I'm down") { Task { await harness.simFriend.goDown(.down) } }
            Button("Sim friend: I'm a maybe") { Task { await harness.simFriend.goDown(.maybe) } }
            Button("Sim friend: withdraw") { Task { await harness.simFriend.withdraw() } }
            Button(harness.simFriend.inRange ? "Sim friend: walk out of range" : "Sim friend: come back in range") {
                Task { await harness.simFriend.setInRange(!harness.simFriend.inRange) }
            }
        } header: {
            Text("Simulated friend (Debug builds only)")
        } footer: {
            Text("A second phone inside this app, paired with this one, running lane F's real Down over an in-process link. When it is down (food or boba, up to $20, next 8 hours) and you go down with overlapping time, the real matching runs: consent sheets, then a match notification on this phone.")
        }

        Section {
            Button("Add a sample friend") {
                Task {
                    await harness.addSampleFriend()
                    await app.friends?.load()
                    status = "Added a friend (not reachable)."
                }
            }
            Button("Send a sample through Outbox") {
                Task { status = await harness.sendSample(through: app.outbox) }
            }
            Button("Send, with the policy changing during consent") {
                Task { status = await harness.sendWithPolicyChangingDuringConsent(through: app.consent) }
            }
            Toggle("Scripted model (next launch)", isOn: $scriptedModel)
            if let status { Text(status).foregroundStyle(.secondary) }
        } header: {
            Text("Fakes (Debug builds only)")
        } footer: {
            Text("Stands in for lane E1 until it merges. Sends go through the app's Outbox (lane G's policy and audit log). An approved sample is not asked again for 10 minutes or until the Down? intent changes. The scripted model returns the same rules every time, including \"karaoke\", so the review flags show, and accepts every offer.")
        }
    }
    #endif
}
