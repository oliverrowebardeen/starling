import Foundation
import Observation
import StarlingCore

/// How long a request stays out.
public enum Expiry: Hashable, Sendable {
    case hours(Int)
    /// Until 11:59 PM today.
    case tonight
    case at(Date)

    public static let presets: [Expiry] = [.hours(1), .hours(3), .tonight]

    public func date(from now: Date, timeZone: TimeZone) -> Date {
        switch self {
        case .hours(let hours): return now.addingTimeInterval(Double(hours) * 3600)
        case .tonight:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let end = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: now) ?? now
            return end > now ? end : now.addingTimeInterval(3600)
        case .at(let date): return date
        }
    }

    public var label: String {
        switch self {
        case .hours(let hours): hours == 1 ? "1 hour" : "\(hours) hours"
        case .tonight: "Tonight"
        case .at: "Custom"
        }
    }
}

/// New, the composer (ADR 0015 decision 2, mockup "New"): the owner types
/// anything, the model picks a skill and fills editable chips (ADR 0016),
/// the owner picks who to ask, and the skill's button sends it through the
/// lifecycle coordinator. Everything the model suggests is shown and
/// editable before anything leaves the phone.
@MainActor
@Observable
public final class ComposerModel {
    /// Who to ask, as the Ask picker offers it (ADR 0020). Every choice
    /// goes through `Audience.resolve`, so exceptions, groups, and the
    /// owner's per-friend rules mean the same thing everywhere.
    public enum AudienceChoice: Hashable, Sendable {
        case allFriends, closeFriends
        case group(GroupID)
        /// Everyone but the friends in `excepted`.
        case everyoneExcept
        /// Exactly the friends in `picked`.
        case pick
    }

    /// One skill tile under "Or start with".
    public struct Tile: Hashable, Sendable, Identifiable {
        public var id: SkillID { skill.id }
        public let skill: SkillDescriptor
        public let canStart: Bool
        /// The summary, or why the skill cannot run now.
        public let subtitle: String
    }

    /// One friend in the Ask row, with their pair symbol drawn from `id`.
    public struct AudienceFriend: Hashable, Sendable, Identifiable {
        public let id: PeerID
        public let name: String
        public let isIncluded: Bool
        /// False when their card says they cannot run the chosen skill.
        public let canRun: Bool
    }

    /// A request that continues a plan (Keep it going, ADR 0012).
    public struct ChainDraft: Hashable, Sendable {
        public let link: ChainLink
        public let inputs: [Artifact]
        public let parentSkill: SkillRef
        /// Topics and permissions this step adds over what the plan already
        /// shared. Non-empty means the owner sees them before starting.
        public let adds: SkillExposure
        /// The parent plan's people. A chained request goes only to them
        /// (ADR 0020 decision 9.3), whatever artifacts the next skill
        /// accepts: Down for… after Find a time takes only the time slot.
        public let allowed: Set<PeerID>
    }

    /// Every edit the owner makes to the draft bumps `generation`, so a
    /// parser result or a send that started on an older draft is dropped
    /// instead of overwriting what the owner reviewed (review of PR #54,
    /// finding 5).
    public private(set) var generation: UInt64 = 0

    public var text = "" { didSet { if text != oldValue { generation &+= 1 } } }
    public private(set) var skill: SkillID?
    /// Whether the model chose the skill (the chip is highlighted).
    public private(set) var routedByModel = false
    public private(set) var isUnderstanding = false
    public var constraints = ConstraintSet.empty { didSet { if constraints != oldValue { generation &+= 1 } } }
    public var audience = AudienceChoice.allFriends { didSet { if audience != oldValue { generation &+= 1 } } }
    public var picked: Set<PeerID> = [] { didSet { if picked != oldValue { generation &+= 1 } } }
    /// Friends left out under Everyone except.
    public var excepted: Set<PeerID> = [] { didSet { if excepted != oldValue { generation &+= 1 } } }
    /// Ask quietly or Invite, when the skill offers both; nil means the
    /// skill's default (ADR 0020).
    public var mode: SendMode? { didSet { if mode != oldValue { generation &+= 1 } } }
    public var expiry = Expiry.hours(3) { didSet { if expiry != oldValue { generation &+= 1 } } }
    public private(set) var chain: ChainDraft?
    public private(set) var notice: String?
    public private(set) var isSending = false
    /// Set after the owner's first request: "Want a heads-up when friends
    /// are up for it?" (ADR 0013 decision 2).
    public var offerNotifications = false

    public let lifecycle: LifecycleCoordinator
    public let settings: SettingsModel
    public let cards: PeerCards
    public let permissions: PermissionGate
    public let chipFormatter: ChipFormatter
    private let skillModel: (any SkillModel)?
    private let friends: @MainActor () -> [PairedPeer]
    private let savedRules: @MainActor () -> OwnerRules?
    private let localPeer: PeerID?
    /// Runs before every send: the first time, the deliberate Local Network
    /// prompt and the radios (ADR 0013).
    public var beforeFirstRequest: @MainActor () async -> Void
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone

    public init(
        skillModel: (any SkillModel)?,
        lifecycle: LifecycleCoordinator,
        settings: SettingsModel,
        cards: PeerCards,
        permissions: PermissionGate,
        friends: @escaping @MainActor () -> [PairedPeer],
        savedRules: @escaping @MainActor () -> OwnerRules?,
        localPeer: PeerID?,
        formatter: ValueFormatter = ValueFormatter(),
        beforeFirstRequest: @escaping @MainActor () async -> Void = {},
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.skillModel = skillModel
        self.lifecycle = lifecycle
        self.settings = settings
        self.cards = cards
        self.permissions = permissions
        self.friends = friends
        self.savedRules = savedRules
        self.localPeer = localPeer
        self.beforeFirstRequest = beforeFirstRequest
        self.now = now
        timeZone = formatter.timeZone
        chipFormatter = ChipFormatter(values: formatter, now: now)
    }

    public var registry: SkillRegistry { lifecycle.registry }

    public var descriptor: SkillDescriptor? { skill.flatMap(registry.descriptor(for:)) }

    /// Whether the model can route and fill chips in this build.
    public var understands: Bool { skillModel != nil }

    // MARK: Skills

    private func availability(of skill: SkillID) -> SkillAvailability {
        guard lifecycle.skillsInBuild.contains(skill) else { return .notInThisBuild }
        return registry.availability(of: skill, in: settings.skillSettings)
    }

    public var tiles: [Tile] {
        registry.inBuild(settings.flags).map { skill in
            let availability = availability(of: skill.id)
            return Tile(skill: skill, canStart: availability.isAvailable, subtitle: Self.subtitle(skill, availability))
        }
    }

    static func subtitle(_ skill: SkillDescriptor, _ availability: SkillAvailability) -> String {
        switch availability {
        case .available: skill.wording.summary
        case .notInThisBuild: "Not in this build yet"
        case .turnedOff: "Turned off in You"
        case .blockedByPrivacy(let topics): blockedReason(skill, topics)
        }
    }

    /// "Pick a place needs Place. You set Place to Never." (ADR 0014).
    public static func blockedReason(_ skill: SkillDescriptor, _ topics: Set<PrivacyTopic>) -> String {
        let names = topics.sorted().map(\.label)
        let list = PermissionExplanation.names(names)
        return "\(skill.wording.name) needs \(list). You set \(list) to Never."
    }

    /// A tile tap: the owner chose the skill. Chips are refilled for it
    /// when there is text to read.
    public func choose(_ skill: SkillID) async {
        guard skill != self.skill else { return }
        self.skill = skill
        generation &+= 1
        mode = nil
        routedByModel = false
        notice = nil
        if let descriptor, availability(of: skill) == .available, !trimmedText.isEmpty, let skillModel {
            isUnderstanding = true
            defer { isUnderstanding = false }
            await fill(from: trimmedText, for: descriptor, model: skillModel, draft: generation)
        }
    }

    // MARK: Understanding the owner's words

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Routes the text to a skill that can run now and fills its chips
    /// (ADR 0016). Without the model, the owner picks a tile.
    public func understand() async {
        let words = trimmedText
        guard !words.isEmpty, chain == nil else { return }
        guard let skillModel else {
            notice = "Pick what this is below."
            return
        }
        isUnderstanding = true
        defer { isUnderstanding = false }
        notice = nil
        let available = registry.available(in: settings.skillSettings).filter { lifecycle.skillsInBuild.contains($0.id) }
        let draft = generation
        let routed: SkillID?
        do {
            routed = try await skillModel.route(words, among: available).value
        } catch {
            if draft == generation { notice = "Starling couldn't read that. Pick what this is below." }
            return
        }
        // The owner changed the draft while the model was reading it.
        guard draft == generation else { return }
        // The model can only name a skill that can run; code checks anyway.
        guard let routed, let descriptor = available.first(where: { $0.id == routed }) else {
            notice = "Starling isn't sure what this is. Pick one below."
            return
        }
        skill = routed
        routedByModel = true
        await fill(from: words, for: descriptor, model: skillModel, draft: draft)
    }

    private func fill(from words: String, for skill: SkillDescriptor, model: any SkillModel, draft: UInt64) async {
        let parsed: ParsedIntent
        do {
            parsed = try await model.intent(from: words, for: skill, now: now(), timeZone: timeZone).value
        } catch {
            if draft == generation { notice = "Starling couldn't fill this in. Edit the details by hand." }
            return
        }
        // A result for an older draft never overwrites what the owner has
        // since edited, such as a narrower audience.
        guard draft == generation, self.skill == skill.id else { return }
        // Only the skill's own slots: a model answer cannot add an issue
        // the skill does not ask about.
        let slots = Set(skill.intent.slots.map(\.issue))
        constraints = (try? ConstraintSet(parsed.constraints.constraints.filter { slots.contains($0.key) })) ?? .empty
        if let expires = parsed.expiresAt?.date, expires > now() { expiry = .at(expires) }
        if let wanted = parsed.mode, skill.sendModes.contains(wanted) { mode = wanted }
        let named = parsed.mentionedNames.compactMap(friend(named:))
        if !named.isEmpty {
            audience = .pick
            picked = Set(named)
        } else if let audience = parsed.audience {
            apply(audience)
        }
    }

    /// A friend whose nickname is exactly `name`, ignoring case. A name two
    /// friends share picks neither: the owner chooses in the Ask row.
    private func friend(named name: String) -> PeerID? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = friends().filter { $0.nickname.lowercased() == key }
        return matches.count == 1 ? matches[0].id : nil
    }

    private func apply(_ audience: Audience) {
        switch audience {
        case .allFriends: self.audience = .allFriends
        case .closeFriends: self.audience = .closeFriends
        case .picked(let peers):
            let known = Set(friends().map(\.id))
            self.audience = .pick
            picked = Set(peers).intersection(known)
        case .everyoneExcept(let peers):
            let known = Set(friends().map(\.id))
            self.audience = .everyoneExcept
            excepted = Set(peers).intersection(known)
        case .group(let id):
            // Only a group the owner saved; anything else is ignored.
            if settings.audienceBook.groups[id] != nil { self.audience = .group(id) }
        }
    }

    /// The chips under "Starling understood", without the skill's own chip.
    public var chips: [String] {
        var chips = chipFormatter.chips(for: constraints)
        if let descriptor, descriptor.sendModes.count > 1 { chips.append(Self.modeLabel(sendMode)) }
        switch audience {
        case .pick where !picked.isEmpty:
            chips.append("With " + PermissionExplanation.names(audienceFriends.filter(\.isIncluded).map(\.name)))
        case .closeFriends:
            chips.append("Close friends")
        case .group(let id):
            if let group = settings.audienceBook.groups[id] { chips.append(group.name) }
        case .everyoneExcept where !excepted.isEmpty:
            chips.append("Not " + PermissionExplanation.names(audienceFriends.filter { excepted.contains($0.id) }.map(\.name)))
        default:
            break
        }
        if descriptor?.intent.asksForExpiry ?? true { chips.append(chipFormatter.expiry(expiresAt)) }
        return chips
    }

    /// "Down for boba", never "Down for…" alone once there is an activity
    /// (ADR 0017).
    public var skillChip: String? {
        guard let descriptor else { return nil }
        if descriptor.id == .downFor, let activity = activity { return "Down for \(activity)" }
        return descriptor.wording.name
    }

    private var activity: String? {
        for constraint in constraints.constraints[.activity] ?? [] {
            if case .prefers(let liked, _) = constraint.rule, let first = liked.first { return first.value }
        }
        return nil
    }

    public var expiresAt: Date { expiry.date(from: now(), timeZone: timeZone) }

    // MARK: Mode

    /// The mode the request goes with: the owner's choice when the skill
    /// offers it, otherwise the skill's default.
    public var sendMode: SendMode {
        guard let descriptor else { return mode ?? .invite }
        if let mode, descriptor.sendModes.contains(mode) { return mode }
        return descriptor.defaultSendMode
    }

    /// Whether New shows the Ask quietly / Invite choice: only for a skill
    /// with both (ADR 0020 decision 2).
    public var offersModeChoice: Bool { (descriptor?.sendModes.count ?? 0) > 1 }

    public static func modeLabel(_ mode: SendMode) -> String {
        switch mode {
        case .askQuietly: "Ask quietly"
        case .invite: "Invite"
        }
    }

    // MARK: Audience

    /// The Ask picker's choices: all friends, close friends, each saved
    /// group, everyone except, and pick.
    public var audienceOptions: [(choice: AudienceChoice, label: String)] {
        [(.allFriends, "All friends"), (.closeFriends, "Close friends")]
            + settings.groups.map { (.group($0.id), $0.name) }
            + [(.everyoneExcept, "Everyone except…"), (.pick, "Pick friends")]
    }

    public var audienceLabel: String {
        audienceOptions.first { $0.choice == audience }?.label ?? "All friends"
    }

    /// The friends this request may go to at all. A chained step goes only
    /// to the parent plan's people (ADR 0020 decision 9.3).
    private var pool: [PairedPeer] {
        guard let chain else { return friends() }
        return friends().filter { chain.allowed.contains($0.id) }
    }

    /// The audience as Core's `Audience`.
    public var audienceValue: Audience {
        switch audience {
        case .allFriends: .allFriends
        case .closeFriends: .closeFriends
        case .group(let id): .group(id)
        case .everyoneExcept: .everyoneExcept(pool.map(\.id).filter(excepted.contains))
        case .pick: .picked(pool.map(\.id).filter(picked.contains))
        }
    }

    /// Every friend for the Ask row, labeled with `RosterLabels` so two
    /// friends with one nickname are told apart.
    public var audienceFriends: [AudienceFriend] {
        let all = pool
        let names = Dictionary(all.map { ($0.id, $0.nickname) }, uniquingKeysWith: { first, _ in first })
        let labels = RosterLabels.labels(for: all.map(\.id), friends: names)
        let included = Set(chosenFriends)
        return zip(all, labels).map { friend, label in
            AudienceFriend(id: friend.id, name: label, isIncluded: included.contains(friend.id), canRun: canRun(friend.id))
        }
    }

    /// Who the audience names after the owner's rules, before checking
    /// which friends' Starlings run the skill.
    private var chosenFriends: [PeerID] {
        audienceValue.resolve(mode: sendMode, friends: pool.map(\.id), book: settings.audienceBook, canRun: { _ in true })
    }

    /// A friend with no card yet is included; the skill's service checks
    /// support itself when it starts.
    private func canRun(_ peer: PeerID) -> Bool {
        guard let descriptor else { return true }
        return cards.support(of: peer, for: descriptor.ref)?.isSupported ?? true
    }

    /// Who the request goes to: `Audience.resolve` over the friends this
    /// request may reach, keeping those whose Starling runs the skill.
    public var participants: [PeerID] {
        let resolved = audienceValue.resolve(mode: sendMode, friends: pool.map(\.id), book: settings.audienceBook, canRun: canRun)
        // Belt and braces: a chained request never leaves the parent plan.
        guard let allowed = chain?.allowed else { return resolved }
        return resolved.filter(allowed.contains)
    }

    /// "Maya's Starling doesn't do this yet." for chosen friends who cannot
    /// run the skill (ADR 0010 decision 4).
    public var leftOutNote: String? {
        let out = audienceFriends.filter { $0.isIncluded && !$0.canRun }.map(\.name)
        guard !out.isEmpty else { return nil }
        return out.count == 1
            ? "\(out[0])'s Starling doesn't do this yet."
            : "\(PermissionExplanation.names(out))'s Starlings don't do this yet."
    }

    /// A tap on a friend in the Ask row. Under Everyone except it leaves
    /// them out or brings them back; otherwise it switches to Pick, starting
    /// from whoever the audience named.
    public func toggle(_ friend: PeerID) {
        if audience == .everyoneExcept {
            if excepted.contains(friend) { excepted.remove(friend) } else { excepted.insert(friend) }
            return
        }
        if audience != .pick {
            picked = Set(chosenFriends)
            audience = .pick
        }
        if picked.contains(friend) { picked.remove(friend) } else { picked.insert(friend) }
    }

    // MARK: Sending

    /// Why the start button is off, in plain words, or nil when it is on.
    public var blocker: String? {
        guard let descriptor, let skill else { return "Type what you want to do, or pick one below." }
        switch availability(of: skill) {
        case .available: break
        case let other: return Self.subtitle(descriptor, other)
        }
        let missing = descriptor.intent.requiredIssues.subtracting(constraints.constraints.keys)
        if let issue = missing.sorted().first { return Self.missingSlotNote(issue, descriptor) }
        if friends().isEmpty { return "Pair with a friend first, in Friends." }
        if chosenFriends.isEmpty { return "Pick at least one friend to ask." }
        if participants.isEmpty { return leftOutNote }
        return nil
    }

    static func missingSlotNote(_ issue: IssueKey, _ skill: SkillDescriptor) -> String {
        switch issue {
        case .activity: "Add what you want to do, like boba or a walk."
        case .time: "Add when, like tonight or next week."
        case .place: "Add where, like near Franklin."
        default: "Add \(ValueFormatter().issueName(issue).lowercased())."
        }
    }

    /// Off while the model is reading the draft, so the owner never sends
    /// before the chips settle.
    public var canSend: Bool { blocker == nil && !isSending && !isUnderstanding }

    /// The skill's own button label: "See who's up for it" for Down for….
    public var startLabel: String { descriptor?.wording.startAction ?? "Start" }

    /// One line under the button, by mode (ADR 0017, ADR 0020).
    public var footnote: String? {
        guard descriptor != nil else { return nil }
        return switch sendMode {
        case .askQuietly: "If nobody's up for it, nobody sees you asked."
        case .invite: "The friends you ask see this as an invite."
        }
    }

    /// What a chained step adds over what the plan already shared, or nil.
    public var chainAddsNote: String? {
        guard let adds = chain?.adds, !adds.isEmpty else { return nil }
        var parts: [String] = []
        // "Uses", not "shares": since Core v2.1 a skill may use a topic on
        // the phone only (ADR 0019), and the consent sheet shows what is sent.
        if !adds.topics.isEmpty { parts.append("uses your \(PermissionExplanation.names(adds.topics.sorted().map { $0.label.lowercased() }))") }
        if !adds.permissions.isEmpty { parts.append("may ask for \(PermissionExplanation.names(adds.permissions.sorted { $0.rawValue < $1.rawValue }.map(\.label)))") }
        return "This step also " + parts.joined(separator: " and ") + "."
    }

    /// Sends the request. Asks for Local Network the first time (ADR 0013),
    /// then the skill's permission through Starling's sheet, and starts it
    /// through the lifecycle coordinator. Returns the new interaction, or
    /// nil with `notice` saying why.
    @discardableResult
    public func send() async -> InteractionID? {
        guard canSend, let descriptor else { return nil }
        isSending = true
        defer { isSending = false }
        notice = nil

        // The request is fixed here, from the draft the owner reviewed.
        // Anything awaited after this point (Local Network, the calendar
        // sheet) cannot change who it goes to or what it says, and an edit
        // or Cancel meanwhile drops the send.
        let reviewed = generation
        let rules: OwnerRules
        do {
            rules = try StandingRules.forRequest(intent: constraints, saved: savedRules(), privacy: settings.settings.privacy)
        } catch {
            notice = "These details and your rules together are too many to send. Remove a chip or a rule."
            return nil
        }
        let recipients = participants
        let names = audienceFriends.filter { $0.isIncluded && $0.canRun }.map(\.name)
        let audienceValue = audienceValue
        let sendMode = sendMode
        let chain = chain
        let request = SkillRequest(
            interaction: InteractionID(),
            conversation: ConversationID(),
            intent: SkillIntent(skill: descriptor.ref, rules: rules, audience: audienceValue, mode: sendMode, expiresAt: Timestamp(expiresAt)),
            participants: recipients,
            inputs: chain?.inputs ?? [],
            chainedFrom: chain?.link.parentConversation
        )

        await beforeFirstRequest()
        // Location is asked when the owner lets the agent suggest nearby
        // places, and photos after a plan ends, not at the start.
        var fallback: String?
        if descriptor.permissions.contains(.calendarFullAccess) {
            if case .askInstead(let text?) = await permissions.prepare(.calendarFullAccess, for: descriptor, friends: names, settings: settings) {
                fallback = text
            }
        }
        guard reviewed == generation else {
            notice = "You changed the request while Starling was asking. Check it and tap again."
            return nil
        }

        do {
            let id = try await lifecycle.start(request, chain: chain?.link, settings: settings.skillSettings)
            clear()
            notice = fallback
            if !settings.settings.notificationsOffered { offerNotifications = true }
            return id
        } catch {
            notice = Self.refusalNote(error, descriptor)
            return nil
        }
    }

    /// "Suggest places near me" in Pick a place: location is asked here,
    /// the first time the owner wants nearby places, not when the skill
    /// starts (ADR 0013 decision 2). Granted adds "nearby" to the chips;
    /// otherwise the owner types an area.
    public func suggestNearby() async {
        guard let descriptor else { return }
        let names = audienceFriends.filter { $0.isIncluded && $0.canRun }.map(\.name)
        switch await permissions.prepare(.locationWhenInUse, for: descriptor, friends: names, settings: settings) {
        case .granted, .limited:
            var all = constraints.constraints
            guard let nearby = try? Keyword("nearby"), let rule = try? Constraint(.prefers(liked: [nearby], avoided: [])) else { return }
            if !(all[.place] ?? []).contains(rule) { all[.place, default: []].append(rule) }
            if let updated = try? ConstraintSet(all) { constraints = updated }
            notice = nil
        case .askInstead(let fallback):
            notice = fallback ?? "Type an area instead, like near Franklin."
        case .unavailable:
            notice = "Type an area instead, like near Franklin."
        }
    }

    static func refusalNote(_ refusal: StartRefusal, _ skill: SkillDescriptor) -> String {
        switch refusal {
        case .notInThisBuild: "\(skill.wording.name) isn't in this build yet."
        case .unsupported: "None of these friends' Starlings do this yet."
        case .blockedByPrivacy(let topics): blockedReason(skill, topics)
        case .failed: "Starling couldn't start this. Try again."
        case .notSaved: "Starling couldn't save this on your phone, so nothing was sent. Try again."
        }
    }

    /// Cancel: clears the draft (ADR 0015 decision 2).
    public func clear() {
        // Also invalidates a send waiting on a permission sheet.
        generation &+= 1
        text = ""
        skill = nil
        routedByModel = false
        constraints = .empty
        audience = .allFriends
        picked = []
        excepted = []
        mode = nil
        expiry = .hours(3)
        chain = nil
        notice = nil
    }

    // MARK: Keep it going

    /// Opens New on a chained step from a plan (ADR 0012): the plan's
    /// people, the plan as input, and what the step adds shown before the
    /// owner taps start. Nothing runs without that tap.
    public func continuePlan(_ parent: Interaction, with next: SkillDescriptor) {
        guard let plan = parent.plan, let parentSkill = registry.descriptor(for: parent.skill.id) else { return }
        clear()
        var inputs: [Artifact] = []
        if next.accepts.contains(.plan) { inputs.append(.plan(plan)) }
        if next.accepts.contains(.timeSlot), let time = plan.time { inputs.append(.timeSlot(time)) }
        chain = ChainDraft(
            link: ChainLink(
                parent: parent.id, parentConversation: parent.conversation,
                consumed: inputs.map(\.kind), trigger: next.chainTrigger, optedInAt: Timestamp(now())
            ),
            inputs: inputs,
            parentSkill: parent.skill,
            adds: next.exposure.adding(over: parentSkill.exposure),
            allowed: Set(plan.attendees.peers).subtracting(localPeer.map { [$0] } ?? [])
        )
        skill = next.id
        audience = .pick
        picked = Set(plan.attendees.peers.filter { $0 != localPeer })
    }
}

extension PrivacyTopic {
    /// "Place", "Budget": the topic's name in You and on the timeline.
    public var label: String {
        switch self {
        case .time: "Time"
        case .activity: "Activity"
        case .place: "Place"
        case .location: "Exact location"
        case .budget: "Budget"
        case .diet: "Diet"
        case .people: "People"
        case .photos: "Photos"
        case .interests: "Interests"
        case .calendarDetails: "Calendar details"
        }
    }
}

extension SystemPermission {
    public var label: String {
        switch self {
        case .calendarFullAccess: "your calendar"
        case .locationWhenInUse: "your location"
        case .photoLibrary: "your photos"
        }
    }
}
