import StarlingChaining
import StarlingChangePlan
import StarlingCore
import StarlingDesign
import StarlingFeatures
import SwiftUI

/// "How this came together": every link of the plan's chain and each
/// hand-off, in order (mockup "Plan detail").
struct PlanTimelineView: View {
    let entries: [TimelineEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Image(systemName: entry.isDone ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(entry.isDone ? Color.accentColor : Color.secondary)
                        if index < entries.count - 1 {
                            Rectangle().fill(Color.accentColor.opacity(0.3)).frame(width: 2).frame(maxHeight: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            SkillTag(text: entry.tag, muted: !entry.isDone)
                            Spacer()
                            if let at = entry.at {
                                Text(at, style: .time).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Text(entry.text)
                    }
                    .padding(.bottom, 16)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// "What left your phone": what was shared, from the egress log, and what
/// stayed (mockup "Plan detail").
struct EgressAuditView: View {
    let shared: [String]
    let kept: [String]
    var isComplete = true

    var body: some View {
        LabeledContent("Shared") {
            Text(shared.isEmpty ? "Nothing yet" : shared.joined(separator: ", ")).multilineTextAlignment(.trailing)
        }
        if isComplete {
            LabeledContent("Kept on your phone") {
                Text(kept.isEmpty ? "Nothing else" : kept.joined(separator: ", ")).multilineTextAlignment(.trailing)
            }
        } else {
            Text("Starling couldn't confirm what one send included, so it can't say what stayed on your phone.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// The confirmed plan at a glance: when, what, who.
struct PlanCard: View {
    let detail: PlanDetail
    let chips: ChipFormatter

    var body: some View {
        HStack(spacing: 14) {
            if let time = detail.plan?.time {
                VStack(spacing: 2) {
                    Text(chips.dayWord(time.start).uppercased()).font(.caption2.weight(.bold))
                    Text(time.start, format: .dateTime.hour().minute()).font(.title3.weight(.semibold))
                }
                .foregroundStyle(.tint)
                .padding(10)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(detail.plan?.place?.name.rawValue ?? detail.title).font(.headline)
                Text(detail.people).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Keep it going" (ADR 0012): hand-offs and the chained skills every
/// friend in the plan supports. A chain the group cannot run is not shown.
struct KeepItGoingList: View {
    let app: AppModel
    let root: Interaction
    let detail: PlanDetail
    let continueWith: (ChainSuggestion) -> Void
    @State private var addingToCalendar = false
    @State private var messaging = false

    var body: some View {
        Section {
            if let draft = detail.calendar {
                HStack {
                    VStack(alignment: .leading) {
                        // After a change, the event added before is out of
                        // date (ADR 0022). Without calendar access Starling
                        // can't edit it, only add the new details.
                        Text(detail.calendarIsOutdated ? "Update in Calendar" : "Add to Calendar")
                        Text(detail.calendarIsOutdated ? "Adds the new details. Remove the old event in Calendar." : "No permission needed")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(detail.calendarIsOutdated ? "Update" : "Add") { addingToCalendar = true }.buttonStyle(.bordered)
                }
                .sheet(isPresented: $addingToCalendar) {
                    CalendarEventEditor(draft: draft) { saved in
                        addingToCalendar = false
                        if saved { app.notes.record(.calendar, for: root.id, revision: detail.plan?.revision) }
                    }
                    .ignoresSafeArea()
                }
            }
            ForEach(app.chainSuggestions(after: root)) { row in
                Button {
                    continueWith(row)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(Self.prompt(for: row.skill)).foregroundStyle(.primary)
                                SkillTag(text: row.skill.wording.name)
                            }
                            Text(Self.subtitle(for: row.skill)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
            }
            MessageGroupButton(app: app, root: root, detail: detail)
        } header: {
            Text("Keep it going")
        }
    }

    static func prompt(for skill: SkillDescriptor) -> String {
        switch skill.id {
        case .pickAPlace: "Somewhere else?"
        case .findATime: "Another time?"
        default: skill.wording.name
        }
    }

    static func subtitle(for skill: SkillDescriptor) -> String {
        switch skill.id {
        case .pickAPlace: "Your agents agree on a new spot"
        case .findATime: "Your agents agree on when"
        default: skill.wording.summary
        }
    }
}

/// Message the group (ADR 0018 decision 2): Messages with the friends the
/// owner linked to a contact on this phone. The first time, with no links,
/// it offers to link them and says the link stays here.
struct MessageGroupButton: View {
    let app: AppModel
    let root: Interaction
    let detail: PlanDetail
    var prominent = false
    @State private var composing = false
    @State private var offeringLinks = false

    private var names: String {
        PermissionExplanation.names(app.words.friendNames(detail.plan?.attendees.peers ?? root.participants))
    }

    var body: some View {
        Button {
            if detail.message.recipients.isEmpty && !detail.message.unlinked.isEmpty {
                offeringLinks = true
            } else {
                composing = true
            }
        } label: {
            if prominent {
                Text("Message group").frame(maxWidth: .infinity)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Message the group").foregroundStyle(.primary)
                        Text("Opens Messages with \(names)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
        }
        .disabled(!MessageComposer.canSend)
        .sheet(isPresented: $composing) {
            MessageComposer(draft: detail.message) { sent in
                composing = false
                if sent { app.notes.record(.messages, for: root.id) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $offeringLinks) {
            NavigationStack {
                ContactLinksView(app: app, friends: detail.message.unlinked) {
                    offeringLinks = false
                    composing = true
                }
            }
        }
    }
}

/// Links friends to contacts on this phone so Messages can address them.
struct ContactLinksView: View {
    let app: AppModel
    let friends: [PeerID]
    let done: () -> Void
    @State private var picking: PeerID?

    var body: some View {
        List {
            Section {
                ForEach(friends, id: \.self) { friend in
                    let name = app.words.friendNames([friend]).first ?? "Friend"
                    Button {
                        picking = friend
                    } label: {
                        HStack {
                            PairSymbol(seed: friend.bytes).frame(width: 24, height: 24)
                            Text(app.notes.contactLinks[friend].map { "\(name): \($0.name)" } ?? "Link \(name) to a contact")
                        }
                    }
                }
            } footer: {
                Text("The link stays on this phone. Starling never sends it, and it doesn't need access to your contacts.")
            }
        }
        .navigationTitle("Who's who")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Open Messages", action: done) }
        }
        .sheet(item: Binding(get: { picking.map(PickTarget.init) }, set: { picking = $0?.peer })) { target in
            ContactPicker { link in
                if let link { app.notes.link(target.peer, to: link) }
                picking = nil
            }
            .ignoresSafeArea()
        }
    }

    struct PickTarget: Identifiable {
        let peer: PeerID
        var id: PeerID { peer }
    }
}

/// It's a plan (Confirm, mockup "It's a plan"): the lit logo, who said yes,
/// the plan, and Keep it going.
struct ItsAPlanView: View {
    let app: AppModel
    let root: Interaction
    let continueWith: (ChainSuggestion) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let detail = app.planDetail(root)
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        StatusMark(state: .match).frame(width: 120, height: 120)
                        Text("It's a plan").font(.largeTitle.bold())
                        Text(detail.saidYes).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    PlanCard(detail: detail, chips: app.words.chips)
                }
                KeepItGoingList(app: app, root: root, detail: detail, continueWith: { next in
                    dismiss()
                    continueWith(next)
                })
            }
            .safeAreaInset(edge: .bottom) {
                Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding()
            }
        }
    }
}

/// Plan detail (mockup "Plan detail"): Message group and Directions, how
/// it came together, and what left the phone.
struct PlanDetailView: View {
    let app: AppModel
    let root: Interaction
    let continueWith: (ChainSuggestion) -> Void

    var body: some View {
        let detail = app.planDetail(root)
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(detail.title).font(.title.bold())
                    if !detail.subtitle.isEmpty { Text(detail.subtitle).foregroundStyle(.secondary) }
                }
                HStack(spacing: 12) {
                    MessageGroupButton(app: app, root: root, detail: detail, prominent: true)
                        .buttonStyle(.borderedProminent)
                    if let place = detail.place {
                        Button {
                            Directions.open(place)
                            app.notes.record(.directions, for: root.id)
                        } label: {
                            Text("Directions").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .controlSize(.large)
            }
            Section("How this came together") {
                PlanTimelineView(entries: detail.timeline)
            }
            Section("What left your phone") {
                EgressAuditView(shared: detail.shared, kept: detail.kept, isComplete: detail.auditIsComplete)
            }
            if root.state == .planned {
                KeepItGoingList(app: app, root: root, detail: detail, continueWith: continueWith)
                ChangeThePlanSection(app: app, root: root, continueWith: continueWith)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // Which logs may be missing a send, before "What left your phone"
        // claims anything stayed (P15-E request 4.1).
        .task { await app.refreshAudit() }
    }
}

/// Any interaction that is not a plan yet: where it is, who it is with,
/// what has left the phone so far, and Take it back while it is live.
struct InteractionDetailView: View {
    let app: AppModel
    let id: InteractionID

    var body: some View {
        if let interaction = app.lifecycle.interaction(id), let summary = app.words.summary(interaction) {
            let detail = app.planDetail(interaction)
            List {
                Section {
                    HStack(spacing: 16) {
                        StatusMark(state: summary.pose.mark).frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            SkillTag(text: summary.tag)
                            Text(summary.status).font(.headline)
                        }
                    }
                }
                Section("With") {
                    ForEach(RosterRow.rows(for: interaction.participants, friends: friendNames, me: app.localPeer)) { RosterRowView(row: $0) }
                }
                Section("What left your phone") {
                    EgressAuditView(shared: detail.shared, kept: detail.kept, isComplete: detail.auditIsComplete)
                }
                if app.placeYesIsFinal(interaction) {
                    Section { Text(AppModel.placeYesIsFinalNote).foregroundStyle(.secondary) }
                } else if interaction.role == .initiator, !interaction.state.isFinal, interaction.state != .planned {
                    Section {
                        Button("Take it back", role: .destructive) { Task { await app.lifecycle.withdraw(id) } }
                    } footer: {
                        Text("Friends learn nothing beyond that there's no plan.")
                    }
                }
            }
            .navigationTitle(summary.title)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("This is gone", systemImage: "tray")
        }
    }

    private var friendNames: [PeerID: String] {
        Dictionary((app.friends?.friends ?? []).map { ($0.id, $0.nickname) }, uniquingKeysWith: { first, _ in first })
    }
}

/// "Suggest a change" and "Leave this plan" (ADR 0022). A suggestion goes
/// to everyone else in the plan and applies only if they all say yes;
/// leaving needs nobody's agreement.
struct ChangeThePlanSection: View {
    let app: AppModel
    let root: Interaction
    let continueWith: (ChainSuggestion) -> Void
    @State private var suggesting = false
    @State private var confirmingLeave = false
    @State private var notice: String?

    var body: some View {
        Section {
            Button("Suggest a change") { suggesting = true }
                .disabled(app.changeUnavailableReason(for: root) != nil)
            if let reason = app.changeUnavailableReason(for: root) {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }
            Button("Leave this plan", role: .destructive) { confirmingLeave = true }
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(.orange)
            }
        } footer: {
            Text("A change happens only if everyone says yes. If anyone passes, the plan stays as it was.")
        }
        .sheet(isPresented: $suggesting) {
            SuggestChangeSheet(app: app, root: root) { row in
                suggesting = false
                continueWith(row)
            }
        }
        .confirmationDialog("Leave this plan?", isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Leave this plan", role: .destructive) {
                Task { notice = await app.leavePlan(root) }
            }
        } message: {
            Text("The others see that you left. Nobody else has to agree.")
        }
    }
}

/// What a suggestion changes: a new time, a new activity, a friend to add.
/// A new place or budget goes through Pick a place ("Somewhere else?").
struct SuggestChangeSheet: View {
    let app: AppModel
    let root: Interaction
    let somewhereElse: (ChainSuggestion) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var changesTime = false
    @State private var start: Date
    @State private var end: Date
    @State private var activity = ""
    @State private var adding: PeerID?
    @State private var problem: String?
    @State private var isSending = false

    init(app: AppModel, root: Interaction, somewhereElse: @escaping (ChainSuggestion) -> Void) {
        self.app = app
        self.root = root
        self.somewhereElse = somewhereElse
        let time = root.plan?.time
        let start = time?.start ?? Date().addingTimeInterval(3600)
        _start = State(initialValue: start)
        _end = State(initialValue: time?.end ?? start.addingTimeInterval(2 * 3600))
    }

    var body: some View {
        // The row this sheet shows; tapping Suggest it approves what it adds.
        let shown = app.changeOffer(for: root)
        NavigationStack {
            Form {
                Section("New time") {
                    Toggle("Change the time", isOn: $changesTime)
                    if changesTime {
                        DatePicker("From", selection: $start)
                        DatePicker("Until", selection: $end, in: start.addingTimeInterval(60)...)
                    }
                }
                Section("New activity") {
                    TextField(root.plan?.activity?.value ?? "Dinner, a walk", text: $activity)
                }
                let friends = app.friendsToAdd(to: root)
                if !friends.isEmpty {
                    Section("Add a friend") {
                        Picker("Friend", selection: $adding) {
                            Text("Nobody").tag(PeerID?.none)
                            ForEach(friends, id: \.id) { friend in Text(friend.nickname).tag(PeerID?.some(friend.id)) }
                        }
                    }
                }
                if let place = app.chainSuggestions(after: root).first(where: { $0.id == .pickAPlace }) {
                    Section {
                        Button("Somewhere else?") { somewhereElse(place) }
                    } footer: {
                        Text("A new place or budget goes through Pick a place.")
                    }
                }
                Section {
                    if let row = shown, let note = app.changeAddsNote(row) {
                        Text(note)
                    }
                    Text("Everyone in the plan has to say yes. If anyone passes, the plan stays as it was.")
                        .foregroundStyle(.secondary)
                    if let problem { Text(problem).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Suggest a change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Suggest it") { Task { await suggest(shown) } }.disabled(isSending)
                }
            }
        }
    }

    /// - Parameter shown: the row this sheet showed, whose additions the
    ///   tap approves.
    private func suggest(_ shown: ChainSuggestion?) async {
        let words = activity.trimmingCharacters(in: .whitespacesAndNewlines)
        let time = changesTime ? try? TimeSlot(start: start, end: end) : nil
        if changesTime, time == nil { problem = "That time can't be used. Try a shorter one."; return }
        let keyword: Keyword?
        if words.isEmpty { keyword = nil } else {
            guard let parsed = try? Keyword(words) else { problem = "Starling can't use that. Try a few plain words."; return }
            keyword = parsed
        }
        guard time != nil || keyword != nil || adding != nil else { problem = "Pick what to change."; return }
        isSending = true
        defer { isSending = false }
        problem = await app.suggestChange(.change(time: time, activity: keyword, adding: adding), on: root, shown: shown)
        if problem == nil { dismiss() }
    }
}
