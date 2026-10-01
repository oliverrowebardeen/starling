#if DEBUG
// The Developer section is in Debug builds only (ADR 0015 decision 5).
// Release builds have no Developer section and no test-build notices;
// a Release check guards that (requested in docs/requests/P15-A.md).
import StarlingCore
import StarlingFeatures
import SwiftUI

/// Debug tools at the bottom of You: the test-build notices, the
/// lifecycle's dropped events, controls that play friends' side over the
/// scripted skills, and the Phase 0 and Phase 1 link and model tools.
struct DeveloperView: View {
    let app: AppModel
    let harness: DebugHarness
    @AppStorage(DebugHarness.scriptedModelKey) private var scriptedModel = false
    @AppStorage(DebugHarness.denyPermissionsKey) private var denyPermissions = false
    @State private var status: String?

    var body: some View {
        List {
            Section {
                Label("This test build doesn't hide free times. Its matching step uses an insecure stand-in until Nightjar's private set intersection lands.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Label("Skills that haven't merged yet are played by scripted services. Their proposals come from your own chips, not from friends.", systemImage: "theatermasks")
            } header: {
                Text("This is a test build")
            }

            Section {
                Button("Add a sample friend") {
                    Task {
                        await harness.addSampleFriend(to: app)
                        status = "Added a friend for this session (never in the Keychain)."
                    }
                }
                if let friend = app.friends?.friends.first, let driver = harness.driver {
                    Button("\(friend.nickname)'s agent asks when you're free") {
                        Task { await driver.friendAsksForATime(from: friend.id) }
                    }
                    Button("\(friend.nickname) is down for tacos too") {
                        Task { await driver.friendIsDownToo(friend.id) }
                    }
                }
                if let driver = harness.driver {
                    Toggle("Propose automatically", isOn: Binding(get: { driver.autoPropose }, set: { driver.autoPropose = $0 }))
                    ForEach(app.lifecycle.interactions.filter { $0.role == .initiator && $0.state == .negotiating }) { item in
                        Button("Nobody's up for \(app.words.summary(item)?.title ?? "it")") { Task { await driver.nobodyUp(item.id) } }
                    }
                }
                Button("Send a sample through Outbox") {
                    Task { status = await harness.sendSample(through: app) }
                }
                if let status { Text(status).foregroundStyle(.secondary) }
            } header: {
                Text("Play a friend's side")
            }

            Section {
                Toggle("System alerts say Don't Allow", isOn: $denyPermissions)
                Button("Forget permission answers") { DebugPermissionAccess.reset() }
                Toggle("Scripted rules model (next launch)", isOn: $scriptedModel)
            } header: {
                Text("Permissions and model")
            } footer: {
                Text("Calendar, location, and photos are stand-ins until lanes C, D, and E merge: Starling's sheet is real, the system alert is simulated.")
            }

            Section {
                if app.lifecycle.dropped.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(app.lifecycle.dropped.reversed()) { drop in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(drop.skill.rawValue): \(String(describing: drop.reason))").font(.footnote.monospaced())
                        Text(verbatim: drop.event).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            } header: {
                Text("Dropped lifecycle events")
            } footer: {
                Text("Stale proposals and questions, unknown consent requests, and invalid transitions leave the interaction unchanged (ADR 0201).")
            }

            Section {
                NavigationLink("Wi-Fi Aware") { WiFiAwareView(app: app) }
                NavigationLink("Audit log") { AuditLogView(log: LiveServices.auditLog, friends: app.friends?.friends ?? []) }
                NavigationLink("Model Bench", destination: ModelBenchView())
                NavigationLink("Nearby", destination: NearbyView())
            } header: {
                Text("Links and model")
            } footer: {
                Text("Nearby links are not encrypted, so don't send anything personal.")
            }
        }
        .navigationTitle("Developer")
        .task { harness.driver?.run() }
    }
}
#endif
