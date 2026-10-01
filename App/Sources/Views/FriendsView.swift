import StarlingCore
import StarlingDesign
import StarlingFeatures
import SwiftUI

/// Friends (ADR 0015 decision 3): pairings with pair symbols, each
/// friend's history and supported skills from their card, and Add friend,
/// which is pairing in person.
struct FriendsView: View {
    let app: AppModel
    @State private var pairing: PairingSheet?

    var body: some View {
        Group {
            if let model = app.friends {
                list(model)
            } else {
                NotInBuildView(feature: "Friends", detail: "Pairing arrives when the identity and Wi-Fi Aware lanes merge.")
            }
        }
        .navigationTitle("Friends")
        .toolbar {
            if app.friends != nil {
                Button("Add friend", systemImage: "plus") { addFriend() }
            }
        }
        .sheet(item: $pairing, onDismiss: { Task { await app.friends?.load() } }) { sheet in
            NavigationStack { PairingView(model: sheet.model) { pairing = nil } }
        }
    }

    private func list(_ model: FriendsModel) -> some View {
        let labels = RosterLabels.labels(for: model.friends.map(\.id), friends: Dictionary(model.friends.map { ($0.id, $0.nickname) }, uniquingKeysWith: { a, _ in a }))
        return List {
            if let notice = model.notice { NoticeSection(text: notice) }
            if !model.friends.isEmpty {
                Section {
                    ForEach(app.settings.groups) { group in
                        NavigationLink(value: GroupRoute(id: group.id)) {
                            LabeledContent(group.name, value: group.members.count == 1 ? "1 friend" : "\(group.members.count) friends")
                        }
                    }
                    NavigationLink("New group", value: GroupRoute(id: nil))
                } header: {
                    Text("Groups")
                } footer: {
                    Text("Groups stay on this phone. Nobody sees which groups they're in.")
                }
            }
            ForEach(Array(zip(model.friends, labels)), id: \.0.id) { friend, label in
                NavigationLink(value: friend.id) {
                    HStack(spacing: 12) {
                        PairSymbol(seed: friend.id.bytes).frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label)
                            Text(supportLine(friend.id)).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.isReachable(friend.id) {
                            Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.green)
                                .accessibilityLabel("Nearby now")
                        }
                    }
                }
            }
        }
        .overlay {
            if model.isLoaded && model.friends.isEmpty {
                ContentUnavailableView {
                    Label("No friends yet", systemImage: "person.2")
                } description: {
                    Text("Pair in person: you both tap Add friend and check the codes match.")
                } actions: {
                    Button("Add friend") { addFriend() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .refreshable { await model.load() }
        .navigationDestination(for: PeerID.self) { id in FriendDetailView(app: app, model: model, id: id) }
        .navigationDestination(for: GroupRoute.self) { route in GroupEditor(app: app, model: model, id: route.id) }
    }

    private func supportLine(_ friend: PeerID) -> String {
        guard let card = app.cards.card(for: friend) else { return "Hasn't said what their Starling does yet" }
        let names = app.services.registry.inBuild(app.settings.flags).filter { card.support(for: $0.ref).isSupported }.map(\.wording.name)
        return names.isEmpty ? "Their Starling doesn't do these skills yet" : names.joined(separator: ", ")
    }

    /// Local Network is asked at the first Pair (ADR 0013).
    private func addFriend() {
        Task {
            await app.ensureLocalNetwork()
            pairing = PairingSheet(app.makePairing())
        }
    }
}

struct FriendDetailView: View {
    let app: AppModel
    let model: FriendsModel
    let id: PeerID
    @State private var renaming = false
    @State private var newName = ""
    @State private var removing = false
    @State private var linking = false

    var body: some View {
        if let friend = model.friends.first(where: { $0.id == id }) {
            List {
                Section {
                    HStack(spacing: 16) {
                        PairSymbol(seed: friend.id.bytes).frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(friend.nickname).font(.title2.bold())
                            Text("Paired \(friend.pairedAt.date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Close friend", isOn: Binding(get: { app.settings.isClose(id) }, set: { on in Task { await app.settings.setClose(id, on) } }))
                    Picker("When you ask friends", selection: Binding(
                        get: { app.settings.rule(for: id) },
                        set: { rule in Task { await app.settings.setRule(rule, for: id) } }
                    )) {
                        Text("Like anyone else").tag(FriendRule?.none)
                        Text("Always include").tag(FriendRule?.some(.alwaysInclude))
                        Text("Never include").tag(FriendRule?.some(.neverInclude))
                        Text("Only ask quietly").tag(FriendRule?.some(.quietOnly))
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let error = app.settings.audienceError {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        Text(Self.ruleNote(app.settings.rule(for: id)))
                    }
                }

                Section {
                    if let card = app.cards.card(for: id) {
                        ForEach(app.services.registry.inBuild(app.settings.flags)) { skill in
                            LabeledContent(skill.wording.name, value: Self.support(card.support(for: skill.ref)))
                        }
                        LabeledContent("Their agent", value: app.services.formatter.locality(card.model))
                    } else {
                        Text("Their Starling hasn't said what it does yet. It will next time you're both nearby.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("What their Starling does")
                }

                Section {
                    if let link = app.notes.contactLinks[id] {
                        LabeledContent("Contact", value: link.name)
                        Button("Unlink contact", role: .destructive) { app.notes.unlink(id) }
                    } else {
                        Button("Link to a contact") { linking = true }
                    }
                } header: {
                    Text("For Message the group")
                } footer: {
                    Text("The link stays on this phone. Starling never sends it.")
                }

                Section("History") {
                    let history = app.lifecycle.interactions
                        .filter { $0.participants.contains(id) && app.words.isVisible($0) }
                        .sorted { $0.updatedAt > $1.updatedAt }
                        .compactMap(app.words.summary)
                    if history.isEmpty {
                        Text("Nothing yet").foregroundStyle(.secondary)
                    }
                    ForEach(history) { summary in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.title)
                            Text("\(summary.skill.wording.name) · \(summary.status)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    if model.canRename {
                        Button("Rename") {
                            newName = friend.nickname
                            renaming = true
                        }
                    }
                    Button("Unpair", role: .destructive) { removing = true }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $renaming) { renameSheet(friend) }
            .sheet(isPresented: $linking) {
                ContactPicker { link in
                    if let link { app.notes.link(id, to: link) }
                    linking = false
                }
                .ignoresSafeArea()
            }
            .confirmationDialog("Unpair \(friend.nickname)?", isPresented: $removing, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { Task { await app.unpair(id) } }
            } message: {
                Text("To pair again, you'll need to be together.")
            }
        } else {
            ContentUnavailableView("Not paired", systemImage: "person.crop.circle.badge.xmark")
        }
    }

    private func renameSheet(_ friend: PairedPeer) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $newName)
                } footer: {
                    if let warning = model.nicknameWarning(newName, for: id) {
                        Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        Text("Only you see this name.")
                    }
                }
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { renaming = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.nicknameWarning(newName, for: id) == nil ? "Save" : "Save anyway") {
                        Task {
                            _ = await model.rename(id, to: newName)
                            renaming = false
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// What a standing rule does (ADR 0020 decision 7), in one line.
    static func ruleNote(_ rule: FriendRule?) -> String {
        switch rule {
        case nil: "Only you see this name, whether they're a close friend, and any rule you set here."
        case .alwaysInclude?: "Added whenever you ask a group of friends, unless you leave them out that time. Only you see this."
        case .neverInclude?: "Left out whenever you ask a group of friends. You can still pick them by name. They can't tell."
        case .quietOnly?: "Asked only quietly, so they never get an invite they could see. They can't tell."
        }
    }

    static func support(_ support: SkillSupport) -> String {
        switch support {
        case .supported: "Yes"
        case .missing: "Doesn't do this yet"
        case .incompatible: "Needs an update"
        }
    }
}

/// A saved group to edit, or nil for a new one.
struct GroupRoute: Hashable {
    let id: GroupID?
}

/// Creates or edits one of the owner's private groups (ADR 0020).
struct GroupEditor: View {
    let app: AppModel
    let model: FriendsModel
    let id: GroupID?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var members: Set<PeerID> = []
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField("Name, like Climbing", text: $name)
            } footer: {
                Text("Only you see this group and its name.")
            }
            Section("Who's in it") {
                ForEach(model.friends, id: \.id) { friend in
                    Toggle(isOn: Binding(get: { members.contains(friend.id) }, set: { if $0 { members.insert(friend.id) } else { members.remove(friend.id) } })) {
                        HStack {
                            PairSymbol(seed: friend.id.bytes).frame(width: 24, height: 24)
                            Text(friend.nickname)
                        }
                    }
                }
            }
            if let error = app.settings.audienceError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            if let id {
                Section {
                    Button("Delete group", role: .destructive) {
                        Task {
                            // Close only once the change is saved.
                            if await app.settings.deleteGroup(id) { dismiss() }
                        }
                    }
                }
            }
        }
        .navigationTitle(id == nil ? "New group" : "Group")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        guard let group = try? FriendGroup(id: id ?? GroupID(), name: name, members: members) else { return }
                        // Close only once the group is saved; a failure
                        // shows above and keeps the edit on screen.
                        if await app.settings.saveGroup(group) { dismiss() }
                    }
                }
                .disabled((try? FriendGroup(name: name, members: members)) == nil)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let id, let group = app.settings.audienceBook.groups[id] {
                name = group.name
                members = group.members
            }
        }
    }
}

/// One pairing sheet, with a fresh ceremony each time it opens.
struct PairingSheet: Identifiable {
    let id = UUID()
    let model: PairingModel

    init?(_ model: PairingModel?) {
        guard let model else { return nil }
        self.model = model
    }
}

/// Says plainly that a feature is missing from this build instead of
/// running it on a fake.
struct NotInBuildView: View {
    let feature: String
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label("\(feature) isn't in this build yet", systemImage: "shippingbox")
        } description: {
            Text(detail)
        }
    }
}
