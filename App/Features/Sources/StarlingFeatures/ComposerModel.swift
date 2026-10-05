import DownFor
import FindATime
import Foundation
import Observation
import PickAPlace
import StarlingChaining
import StarlingCore

/// How long friends can answer a request (not how long the plan lasts).
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

    /// The control's title: what the choice decides.
    public static let controlTitle = "How long friends can answer"

    /// "1 hour", "3 hours", "Until tonight".
    public var label: String {
        switch self {
        case .hours(let hours): hours == 1 ? "1 hour" : "\(hours) hours"
        case .tonight: "Until tonight"
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
        /// Lane E's "Keep it going" row this step came from. Start checks it
        /// again with `ChainPlanner.begin` (ADR 0240).
        public let suggestion: ChainSuggestion
    }

    /// Every edit the owner makes to the draft bumps `generation`, so a
    /// parser result or a send that started on an older draft is dropped
    /// instead of overwriting what the owner reviewed (review of PR #54,
    /// finding 5).
    public private(set) var generation: UInt64 = 0

    /// Only a meaningful change counts as an edit: case and spacing don't
    /// (device test 2, issue #95).
    public var text = "" { didSet { if Self.readingKey(text) != Self.readingKey(oldValue) { generation &+= 1 } } }
    public private(set) var skill: SkillID?
    /// Whether the model chose the skill (the chip is highlighted).
    public private(set) var routedByModel = false
    public private(set) var isUnderstanding = false
    public var constraints = ConstraintSet.empty {
        didSet {
            guard constraints != oldValue else { return }
            generation &+= 1
            let keys = Set(constraints.constraints.keys).union(oldValue.constraints.keys)
            touched(keys.filter { constraints.constraints[$0] != oldValue.constraints[$0] }.map(ComposeChip.Part.issue))
        }
    }
    public var audience = AudienceChoice.allFriends { didSet { if audience != oldValue { generation &+= 1; touched([.audience]) } } }
    public var picked: Set<PeerID> = [] { didSet { if picked != oldValue { generation &+= 1; touched([.audience]) } } }
    /// Friends left out under Everyone except.
    public var excepted: Set<PeerID> = [] { didSet { if excepted != oldValue { generation &+= 1; touched([.audience]) } } }
    /// Ask quietly or Ask directly, when the skill offers both; nil means
    /// the skill's default (ADR 0020).
    public var mode: SendMode? { didSet { if mode != oldValue { generation &+= 1; touched([.mode]) } } }
    public var expiry = Expiry.hours(3) { didSet { if expiry != oldValue { generation &+= 1; touched([.expiry]) } } }

    /// The chips the owner edited or removed since the skill was chosen. A
    /// re-read of the words never changes them (device test 2).
    public private(set) var ownerSet: Set<ComposeChip.Part> = []
    /// True while a reading is applied, so its changes are not the owner's.
    private var applyingReading = false
    /// The words last read, compared by `readingKey`.
    private var lastRead: String?
    /// Whether the chips shown are a finished reading (or the owner's), so
    /// Start can stay on while a newer reading runs.
    private var hasReading = false

    private func touched(_ parts: [ComposeChip.Part]) {
        guard !applyingReading else { return }
        ownerSet.formUnion(parts)
    }

    /// The words as a re-read compares them: case and spacing don't count.
    public static func readingKey(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public var readingKey: String { Self.readingKey(text) }
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
    /// Pick a place's candidates, when Pick a place is in the build.
    public let places: PlacePicker?
    private let skillModel: (any SkillModel)?
    private let friends: @MainActor () -> [PairedPeer]
    private let savedRules: @MainActor () -> OwnerRules?
    private let localPeer: PeerID?
    /// Runs before every send: the first time, the deliberate Local Network
    /// prompt and the radios (ADR 0013).
    public var beforeFirstRequest: @MainActor () async -> Void
    /// Whether a change holds the plan an interaction holds (ADR 0023).
    /// `AppModel` sets it.
    public var planIsChanging: @MainActor (InteractionID) -> Bool = { _ in false }
    let now: @Sendable () -> Date
    let timeZone: TimeZone

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
        places: PlacePicker? = nil,
        beforeFirstRequest: @escaping @MainActor () async -> Void = {},
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.places = places
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

    /// Skills New can start: not ones that only run on a plan (Change the
    /// plan starts from the plan's detail; Swap photos after it ends).
    public var tiles: [Tile] {
        registry.inBuild(settings.flags).filter { $0.chainTrigger == .atConfirm }.map { skill in
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

    /// Lane C's default time for Find a time: the next 7 days, in a meal's
    /// hours when the activity is a meal.
    func findATimeDefault(activity: [Constraint]?) -> [Constraint]? {
        let keyword = activity?.lazy.compactMap { constraint -> Keyword? in
            if case .prefers(let liked, _) = constraint.rule { return liked.first }
            return nil
        }.first
        return try? FindATimeDefaults.timeConstraints(activity: keyword, now: now())
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
        // Another skill: its chips start from the words again.
        ownerSet = []
        hasReading = true
        if skill == .findATime, constraints.constraints[.time] == nil, let time = findATimeDefault(activity: constraints.constraints[.activity]) {
            applyingReading = true
            var next = constraints.constraints
            next[.time] = time
            constraints = (try? ConstraintSet(next)) ?? constraints
            applyingReading = false
        }
        if let descriptor, availability(of: skill) == .available, !trimmedText.isEmpty, let skillModel {
            hasReading = false
            isUnderstanding = true
            defer { isUnderstanding = false; hasReading = true }
            await fill(from: trimmedText, for: descriptor, model: skillModel, draft: generation, key: readingKey)
        }
    }

    // MARK: Understanding the owner's words

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Routes the text to a skill that can run now and fills its chips
    /// (ADR 0016). Without the model, the owner picks a tile.
    /// Re-reads only when the words changed meaningfully (case and spacing
    /// don't count), and keeps every chip the owner edited or removed. While
    /// a re-read runs, Start stays on with the chips already shown; the new
    /// reading applies only if the owner has not touched the draft since.
    public func understand() async {
        let words = trimmedText
        let key = readingKey
        guard !words.isEmpty, chain == nil else { return }
        if key == lastRead, skill != nil { return }
        guard let skillModel else {
            notice = "Pick what this is below."
            return
        }
        isUnderstanding = true
        defer { isUnderstanding = false }
        notice = nil
        let draft = generation
        // A skill the owner picked from the tiles stays picked.
        if skill != nil, !routedByModel, let descriptor {
            await fill(from: words, for: descriptor, model: skillModel, draft: draft, key: key)
            return
        }
        let available = registry.available(in: settings.skillSettings)
            .filter { lifecycle.skillsInBuild.contains($0.id) && $0.chainTrigger == .atConfirm }
        let routed: SkillID?
        do {
            routed = try await skillModel.route(words, among: available).value
        } catch {
            if draft == generation { notice = "Starling couldn't read that. Pick what this is below." }
            return
        }
        // The owner changed the draft while the model was reading it.
        guard draft == generation, !isSending else { return }
        // The model can only name a skill that can run; code checks anyway.
        guard let routed, let descriptor = available.first(where: { $0.id == routed }) else {
            notice = "Starling isn't sure what this is. Pick one below."
            return
        }
        if routed != skill {
            // Another skill: its chips start from the words.
            skill = routed
            ownerSet = []
            hasReading = false
        }
        routedByModel = true
        await fill(from: words, for: descriptor, model: skillModel, draft: draft, key: key)
    }

    private func fill(from words: String, for skill: SkillDescriptor, model: any SkillModel, draft: UInt64, key: String) async {
        defer { if self.skill == skill.id { hasReading = true } }
        let parsed: ParsedIntent
        do {
            parsed = try await model.intent(from: words, for: skill, now: now(), timeZone: timeZone).value
        } catch {
            if draft == generation { notice = "Starling couldn't fill this in. Edit the details by hand." }
            return
        }
        // A result for an older draft never overwrites what the owner has
        // since edited, such as a narrower audience, nor a draft being sent.
        guard draft == generation, !isSending, self.skill == skill.id else { return }
        applyingReading = true
        defer { applyingReading = false }
        lastRead = key
        // Only the skill's own slots: a model answer cannot add an issue
        // the skill does not ask about. A chip the owner edited or removed
        // stays as the owner left it.
        var next: [IssueKey: [Constraint]] = [:]
        for issue in skill.intent.slots.map(\.issue) {
            next[issue] = ownerSet.contains(.issue(issue)) ? constraints.constraints[issue] : parsed.constraints.constraints[issue]
        }
        // Find a time with no days in the words: lane C's default, the
        // next week in the activity's usual hours (P15-C request 6a).
        if skill.id == .findATime, next[.time] == nil {
            next[.time] = findATimeDefault(activity: next[.activity])
        }
        constraints = (try? ConstraintSet(next)) ?? constraints
        if !ownerSet.contains(.expiry), let expires = parsed.expiresAt?.date, expires > now() { expiry = .at(expires) }
        if !ownerSet.contains(.mode), let wanted = parsed.mode, skill.sendModes.contains(wanted) { mode = wanted }
        guard !ownerSet.contains(.audience) else { return }
        // The model reports names only (P15-B request 2). With "everyone
        // except", they are the friends left out; a name that is one of
        // the owner's groups names that group; otherwise they are who to ask.
        let named = parsed.mentionedNames.compactMap(friend(named:))
        if case .everyoneExcept(let peers)? = parsed.audience {
            guard named.count == parsed.mentionedNames.count else {
                // Someone the owner left out can't be told apart: ask nobody
                // until the owner picks, rather than risk asking them.
                audience = .pick
                picked = []
                notice = "Starling couldn't tell who to leave out. Pick who to ask."
                return
            }
            apply(.everyoneExcept(peers + named))
        } else if named.isEmpty, let group = parsed.mentionedNames.lazy.compactMap(group(named:)).first {
            apply(.group(group))
        } else if !named.isEmpty {
            audience = .pick
            picked = Set(named)
        } else if let audience = parsed.audience {
            apply(audience)
        } else {
            // The words no longer name anyone: everyone again.
            audience = .allFriends
            picked = []
            excepted = []
        }
    }

    /// One of the owner's saved groups named exactly `name`, ignoring case.
    private func group(named name: String) -> GroupID? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = settings.groups.filter { $0.name.lowercased() == key }
        return matches.count == 1 ? matches[0].id : nil
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
        chipItems.filter { $0.part != .skill }.map(\.text)
    }

    /// Who the request goes to, when not all friends: "With Maya", "Close
    /// friends", a group's name, "Not Leo".
    var audienceText: String? {
        switch audience {
        case .pick where !picked.isEmpty:
            "With " + PermissionExplanation.names(audienceFriends.filter(\.isIncluded).map(\.name))
        case .closeFriends:
            "Close friends"
        case .group(let id):
            settings.audienceBook.groups[id]?.name
        case .everyoneExcept where !excepted.isEmpty:
            "Not " + PermissionExplanation.names(audienceFriends.filter { excepted.contains($0.id) }.map(\.name))
        default:
            nil
        }
    }

    /// "Down for boba", never "Down for…" alone once there is an activity
    /// (ADR 0017).
    public var skillChip: String? {
        guard let descriptor else { return nil }
        if descriptor.id == .downFor, let activity = activity {
            // In the owner's words as typed (device test, 2026-10-02).
            return "Down for \(ChipFormatter.spelling(of: activity, in: text) ?? activity.value)"
        }
        return descriptor.wording.name
    }

    private var activity: Keyword? {
        for constraint in constraints.constraints[.activity] ?? [] {
            if case .prefers(let liked, _) = constraint.rule, let first = liked.first { return first }
        }
        return nil
    }

    /// When friends can no longer answer. A skill that asks for it (Down
    /// for...) uses the owner's choice. One that does not (Find a time,
    /// Pick a place) stays open until the time it asks about starts (ADR
    /// 0206 decision 12).
    public var expiresAt: Date {
        guard let descriptor, !descriptor.intent.asksForExpiry else { return expiry.date(from: now(), timeZone: timeZone) }
        return Self.openUntil(now: now(), windowStart: askedWindowStart, planStart: chainPlanStart)
    }

    /// A chained request stays open until its plan starts. Otherwise until
    /// the asked-about window starts, but at least a day and at most a week.
    static func openUntil(now: Date, windowStart: Date?, planStart: Date?) -> Date {
        if let planStart, planStart > now { return planStart }
        let day: TimeInterval = 24 * 3600
        let start = windowStart ?? now.addingTimeInterval(day)
        return min(max(start, now.addingTimeInterval(day)), now.addingTimeInterval(7 * day))
    }

    /// The earliest start of the time the request asks about.
    private var askedWindowStart: Date? {
        (constraints.constraints[.time] ?? []).compactMap { constraint -> Date? in
            if case .within(let slots) = constraint.rule { return slots.map(\.start).min() }
            return nil
        }.min()
    }

    /// When the plan a chained request continues starts.
    private var chainPlanStart: Date? {
        for input in chain?.inputs ?? [] {
            if case .plan(let plan) = input, let start = plan.time?.start { return start }
            if case .timeSlot(let slot) = input { return slot.start }
        }
        return nil
    }

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

    /// "Ask quietly" or "Ask directly". Not "Invite", which read as part of
    /// the activity ("Down for an invite").
    public static func modeLabel(_ mode: SendMode) -> String {
        switch mode {
        case .askQuietly: "Ask quietly"
        case .invite: "Ask directly"
        }
    }

    /// What each mode means for the friends asked.
    public static func modeNote(_ mode: SendMode) -> String {
        switch mode {
        case .askQuietly: "Friends see nothing unless they're up for it too."
        case .invite: "Friends see that you asked and can say yes or pass."
        }
    }

    /// "Friends can answer until 4:15 PM": when the request stops taking
    /// answers, never how long the plan lasts.
    public var expiryChip: String { chipFormatter.answerUntil(expiresAt) }

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
        // Down for... says who can't run it by lane B's own rule.
        if descriptor.id == .downFor { return DownForService.unsupported(among: [peer], cards: cards.cards).isEmpty }
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
        // One change per plan at a time (ADR 0023).
        if let chain, PlanChangesInProgress.skills.contains(descriptor.id), planIsChanging(chain.suggestion.parent) {
            return PlanChangesInProgress.note
        }
        if descriptor.id == .pickAPlace, let places {
            if places.chosen.isEmpty { return "Find a few places, or type one." }
            if places.askable(limits: requestLimits).isEmpty { return "None of these fit your limits." }
        }
        if friends().isEmpty { return "Pair with a friend first, in Friends." }
        if chosenFriends.isEmpty { return "Pick at least one friend to ask." }
        if participants.isEmpty { return leftOutNote ?? "None of these friends can get this yet." }
        return nil
    }

    /// Chosen friends whose Starling has not said hello yet, so New cannot
    /// tell what it does (a fresh pairing). Not a reason to stop: their
    /// skill checks again when it starts.
    public var waitingNote: String? {
        let waiting = audienceFriends.filter { $0.isIncluded && cards.card(for: $0.id) == nil }.map(\.name)
        guard !waiting.isEmpty else { return nil }
        let who = PermissionExplanation.names(waiting)
        return waiting.count == 1
            ? "Waiting to hear from \(who)'s Starling. Keep both phones nearby."
            : "Waiting to hear from \(who)'s Starlings. Keep the phones nearby."
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
    /// The limits a request would carry: the chips with the standing rules.
    private var requestLimits: ConstraintSet {
        (try? StandingRules.forRequest(intent: constraints, saved: savedRules(), privacy: settings.settings.privacy).constraints) ?? constraints
    }

    /// Why Start is off, in plain words, every time it is off; nil when it
    /// is on (device test 2, issue #95). While the first reading of the
    /// words runs it says so; a re-read leaves Start on.
    public var sendNote: String? {
        if isUnderstanding, skill == nil || !hasReading { return "Starling is reading this. One moment." }
        return blocker
    }

    public var canSend: Bool { sendNote == nil && !isSending }

    /// The skill's own button label: "See who's up for it" for Down for….
    public var startLabel: String { descriptor?.wording.startAction ?? "Start" }

    /// One line under the button, by mode (ADR 0017, ADR 0020).
    public var footnote: String? {
        guard descriptor != nil else { return nil }
        return switch sendMode {
        case .askQuietly: DownFor.revealNote
        case .invite: "The friends you ask see that you asked."
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
        // Pick a place's candidates are part of what the owner reviewed.
        let places = descriptor.id == .pickAPlace ? places?.chosen : nil
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

        // Candidates exist before anything is sent (P15-D request 2).
        // A chained step: lane E checks the row is still offered and that
        // the owner approved what it adds, then builds the link (ADR 0240).
        // The owner's tap on Start, with the additions shown above it, is
        // the approval.
        var outgoing = request
        var link = chain?.link
        if let chain {
            guard let me = localPeer else {
                notice = "This step can't start in this build."
                return nil
            }
            let tap = Timestamp(now())
            do {
                let start = try ChainPlanner(registry: registry, me: me).begin(
                    chain.suggestion, in: lifecycle.interactions, settings: settings.skillSettings, cards: cards.cards,
                    tap: OwnerTap(at: tap), consent: chain.suggestion.needsConsent ? chain.suggestion.consent(approvedAt: tap) : nil,
                    rules: rules, expiresAt: Timestamp(expiresAt)
                )
                outgoing = SkillRequest(
                    interaction: start.interaction.id, conversation: start.interaction.conversation,
                    intent: request.intent,
                    participants: request.participants.filter(chain.allowed.contains),
                    inputs: start.request.inputs, chainedFrom: start.request.chainedFrom
                )
                link = start.interaction.chain
            } catch {
                notice = "This step can't start now: the plan, a friend's Starling, or your settings changed. Open the plan again."
                return nil
            }
        }
        if let places { await self.places?.stage(places, for: outgoing.interaction) }
        do {
            // A quiet ask goes to each friend separately (amendment 17).
            let id = try await lifecycle.send(outgoing, chain: link, settings: settings.skillSettings).first ?? outgoing.interaction
            if let inviting { lifecycle.addToRequestGroup(id, group: inviting) }
            clear()
            notice = fallback
            if !settings.settings.notificationsOffered { offerNotifications = true }
            return id
        } catch {
            notice = Self.refusalNote(error, descriptor)
            return nil
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
        places?.clear()
        expiry = .hours(3)
        chain = nil
        inviting = nil
        notice = nil
        ownerSet = []
        lastRead = nil
        hasReading = false
    }

    // MARK: One plan from pair plans

    /// The quiet ask whose matched friends this draft invites together.
    public private(set) var inviting: UUID?

    /// Opens New on an Invite to the friends a quiet ask matched with, with
    /// the plans' activity and time (P15-B request 9, ADR 0210 decision
    /// 20). The invitation names who is coming under the people topic.
    public func inviteMatched(_ invite: GroupInvite) {
        clear()
        skill = .downFor
        mode = .invite
        audience = .pick
        picked = Set(invite.friends)
        var issues: [IssueKey: [Constraint]] = [:]
        if let activity = invite.activity, let keyword = try? Keyword(activity), let liked = try? Constraint(.prefers(liked: [keyword], avoided: [])) {
            issues[.activity] = [liked]
        }
        if let time = invite.plans.first?.plan?.time, let within = try? Constraint(.within([time])) { issues[.time] = [within] }
        constraints = (try? ConstraintSet(issues)) ?? .empty
        inviting = invite.group
    }

    // MARK: Keep it going

    /// Opens New on a chained step from a plan (ADR 0012): the plan's
    /// people, the plan as input, and what the step adds shown before the
    /// owner taps start. Nothing runs without that tap.
    public func continuePlan(_ parent: Interaction, with suggestion: ChainSuggestion) {
        guard let plan = parent.plan, parent.id == suggestion.parent else { return }
        clear()
        let next = suggestion.skill
        let inputs: [Artifact] = suggestion.consumes.compactMap { kind in
            switch kind {
            case .plan: .plan(plan)
            case .timeSlot: plan.time.map(Artifact.timeSlot)
            case .attendees: .attendees(plan.attendees)
            case .placeChoice: plan.place.map(Artifact.placeChoice)
            }
        }
        chain = ChainDraft(
            link: ChainLink(
                parent: parent.id, parentConversation: parent.conversation,
                consumed: suggestion.consumes, trigger: next.chainTrigger, optedInAt: Timestamp(now())
            ),
            inputs: inputs,
            parentSkill: parent.skill,
            adds: suggestion.adds,
            allowed: Set(suggestion.participants),
            suggestion: suggestion
        )
        skill = next.id
        audience = .pick
        picked = Set(suggestion.participants)
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
