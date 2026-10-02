import FindATime
import StarlingCore
import StarlingDesign
import StarlingFeatures
import SwiftUI

/// You (ADR 0015 decision 4, mockup "You"): the agent, privacy topics with
/// Share / Ask me / Never (ADR 0014), skills with their permission lines
/// and switches (ADR 0013), the rules, and in Debug builds only, Developer.
struct YouView<Developer: View>: View {
    let app: AppModel
    @ViewBuilder let developer: () -> Developer
    @State private var statuses: [SystemPermission: PermissionStatus] = [:]

    private var settings: SettingsModel { app.settings }

    var body: some View {
        List {
            if settings.loadFailed {
                Section {
                    Label(settings.notice ?? "Your privacy settings couldn't be read.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Use these settings") { Task { await settings.recover() } }
                } footer: {
                    Text("Check every topic and skill below first. Starling keeps the old file aside and sends nothing until you tap Use these settings.")
                }
            } else if let notice = settings.notice {
                NoticeSection(text: notice)
            }
            agent
            NotificationsOffSection(app: app)
            privacy
            skills
            Section {
                NavigationLink("Your rules") { RulesEditorView(model: app.rulesEditor) }
            } footer: {
                Text("Limits your agent always keeps, like no plans before 10. They never leave your phone.")
            }
            #if DEBUG
            Section {
                NavigationLink("Developer") { developer() }
            } footer: {
                Text("Debug builds only.")
            }
            #endif
        }
        .navigationTitle("You")
        .task(id: settings.settings) {
            for permission in SystemPermission.allCases {
                statuses[permission] = await app.permissions.status(of: permission)
            }
        }
    }

    private var agent: some View {
        Section {
            HStack(spacing: 14) {
                PairSymbol.own.frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your agent").font(.headline)
                    Text(locality).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Toggle("Only negotiate with on-device agents", isOn: Binding(
                get: { settings.settings.onlyOnDeviceAgents },
                set: { on in Task { await settings.setOnlyOnDeviceAgents(on) } }
            ))
        } footer: {
            Text("Friends' agents say where their model runs. Starling can't check it yet, so this trusts what they say.")
        }
    }

    private var locality: String {
        switch app.services.agentLocality {
        case .onDevice?: "Runs on this iPhone"
        case .privateCloudCompute?: "Runs in Apple Private Cloud Compute"
        case .thirdPartyCloud(let provider)?: "Runs on \(provider)"
        case ModelLocality.none?: "Uses no language model"
        case nil: "Isn't in this build yet"
        }
    }

    /// Every topic but time and activity has the same control, and each
    /// explains the choice it is set to (ADR 0019).
    private var privacy: some View {
        Section {
            ForEach(PrivacyCopy.topics, id: \.self) { topic in
                let choice = settings.choice(for: topic)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(topic.label)
                        Spacer()
                    }
                    Picker(topic.label, selection: Binding(
                        get: { choice },
                        set: { next in Task { await settings.set(next, for: topic) } }
                    )) {
                        Text("Share").tag(SharingChoice.share)
                        Text("Ask me").tag(SharingChoice.askMe)
                        Text("Never").tag(SharingChoice.never)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(!PrivacyCopy.isSentBySomeSkill(topic) && choice != .never ? PrivacyCopy.notUsedYet : PrivacyCopy.explanation(choice))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        } header: {
            HStack {
                Text("Privacy")
                Spacer()
                Text("Applies to every skill").textCase(nil)
            }
        } footer: {
            Text(PrivacyCopy.overlapNote)
        }
    }

    private var skills: some View {
        Section("Skills") {
            ForEach(app.services.registry.inBuild(settings.flags)) { skill in
                let inBuild = app.lifecycle.skillsInBuild.contains(skill.id)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { inBuild && settings.isOn(skill.id) },
                        set: { on in Task { await settings.setSkill(skill.id, on: on) } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.wording.name)
                            Text(inBuild ? permissionLine(skill) : "Not in this build yet")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!inBuild)
                    let blocking = skill.blockingTopics(in: settings.settings.privacy)
                    if inBuild, !blocking.isEmpty {
                        Text(ComposerModel.blockedReason(skill, blocking)).font(.footnote).foregroundStyle(.orange)
                    }
                    if inBuild, skill.permissions.contains(.calendarFullAccess) {
                        Picker("Find free times", selection: Binding(
                            get: { settings.asksInstead(skill.id) },
                            set: { ask in Task { await settings.setAskInstead(skill.id, ask) } }
                        )) {
                            // Lane C's labels (P15-C request 1).
                            Text(FindATimeCopy.useMyCalendar).tag(false)
                            Text(FindATimeCopy.justAskMe).tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
        }
    }

    /// "No permissions needed", "Calendar · reads busy and free only".
    private func permissionLine(_ skill: SkillDescriptor) -> String {
        guard let permission = skill.permissions.sorted(by: { $0.rawValue < $1.rawValue }).first else { return "No permissions needed" }
        let what: String = switch permission {
        case .calendarFullAccess: settings.asksInstead(skill.id) ? "Calendar · asks you instead" : "Calendar · reads busy and free only"
        case .locationWhenInUse: "Location · asks when you use it"
        case .photoLibrary: "Photos · asks after your first plan"
        }
        switch statuses[permission] {
        case .denied?: return what + " · off in Settings"
        case .limited?: return what + " · selected photos only"
        default: return what
        }
    }
}
