#if DEBUG
// Debug builds only. StarlingFakes includes the insecure PSI stub and
// scripted doubles, so nothing outside `#if DEBUG` may import it (ADR 0140).
import DownFor
import FindATime
import Foundation
import Observation
import PickAPlace
import StarlingAgent
import StarlingChaining
import StarlingCore
import StarlingFakes
import StarlingFeatures
import StarlingIdentity
import StarlingSwapPhotos
import StarlingTransport

/// The Debug composition: the same lane E1 stack as Release (Keychain
/// identity, one PinAuthority, secure LocalP2P and Wi-Fi Aware links, real
/// pairing), with the skills that have not merged yet played by
/// `ScriptedSkillService`s and a `DemoDriver` that moves them through the
/// lifecycle, so Home, New, the cards, and It's a plan can be walked on one
/// phone or the Simulator. Each skill lane's real service replaces its
/// scripted one as it merges.
@MainActor
final class DebugHarness {
    nonisolated static let scriptedModelKey = "dev.scriptedModel"
    nonisolated static let denyPermissionsKey = "dev.denyPermissions"
    /// Plays Down for... with a scripted service and the demo driver, for a
    /// walk-through on one phone, instead of lane B's service.
    nonisolated static let scriptedDownForKey = "dev.scriptedDownFor"

    let usesScriptedModel: Bool
    let usesScriptedDownFor: Bool
    /// Friends that exist only in this Debug session. Never written to the
    /// Keychain.
    let overlay = InMemoryPairedPeerStore()
    /// Skills played by scripted services: Down for... only when the
    /// Developer section asks for it.
    let skills: [ScriptedSkillService]
    /// Debug's registry: every lane's real descriptor, or the sample Down
    /// for... while it is scripted.
    var registry: SkillRegistry {
        try! SkillRegistry([usesScriptedDownFor ? SampleSkills.downFor : DownFor.descriptor, FindATimeSkill.descriptor, PickAPlaceSkill.descriptor, SwapPhotos.descriptor])
    }
    private(set) var driver: DemoDriver?
    private(set) var friends: (any PairedPeerStore)?
    private(set) var localPeer: PeerID?
    /// Fixed per launch so a repeated demo send has an identical disclosure.
    let sampleStart: Date
    private var sampleCount = 0

    init(defaults: UserDefaults = .standard) {
        usesScriptedModel = defaults.bool(forKey: Self.scriptedModelKey)
        // The headless self-test walks the demo, so it needs the script.
        usesScriptedDownFor = defaults.bool(forKey: Self.scriptedDownForKey) || defaults.bool(forKey: "starlingSelfTestLifecycle")
        skills = usesScriptedDownFor ? [ScriptedSkillService(descriptor: SampleSkills.downFor)] : []
        sampleStart = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 3600).rounded(.up) * 3600)
    }

    func services(rules: any RulesStore = LiveServices.rulesStore()) async throws -> AppServices {
        let identity = try await KeychainIdentityKeyStore().loadOrCreate()
        let model = FoundationModelsAgent()
        let agent: any AgentModel = usesScriptedModel ? Self.scriptedAgent() : model
        let skillModel: any SkillModel = usesScriptedModel ? Self.scriptedSkillModel() : model
        let scriptedDownFor = usesScriptedDownFor
        let friends = OverlayPairedPeerStore(base: KeychainPairedPeerStore(), overlay: overlay)
        let links = SecureLinks.make(identity: identity, friends: friends)
        self.friends = friends
        localPeer = identity.peerID
        let skills = skills
        driver = DemoDriver(me: identity.peerID, services: skills)
        let ledger = LiveServices.ledger()
        let places = LiveServices.places()
        let interactions = LiveServices.interactionStore()
        let choices = OwnerChoices()

        return AppServices(
            agent: agent,
            skillModel: skillModel,
            registry: registry,
            makeSkills: { outbox in
                // Lane B's service on the insecure PSI stub, which only
                // Debug may link (ADR 0144).
                let downFor = scriptedDownFor ? [] : [LiveServices.downFor(me: identity.peerID, outbox: outbox, agent: agent, psi: InsecurePSIStub(), friends: friends, ledger: ledger)]
                return skills + downFor + [
                    LiveServices.findATime(me: identity.peerID, outbox: outbox, friends: friends, ledger: ledger, choices: choices),
                    LiveServices.pickAPlace(me: identity.peerID, outbox: outbox, friends: friends, staged: places.staged, rules: rules, ledger: ledger,
                                            interactions: interactions),
                    LiveServices.swapPhotos(me: identity.peerID, outbox: outbox, ledger: ledger, interactions: interactions),
                ]
            },
            interactions: interactions,
            settings: LiveServices.settingsStore(),
            rules: rules,
            peers: friends,
            pairing: links.pairingDirectory,
            unpair: links.unpair,
            rename: links.rename,
            inboxEvents: links.inboxEvents,
            makePolicy: LiveServices.policy(peers: friends),
            auditLog: LiveServices.auditLog,
            sequences: try? FileSentSequenceStore.standard(),
            ledger: ledger,
            egressJournal: LiveServices.egressJournal(),
            placeFinder: places.finder,
            stagedPlaces: places.staged,
            choices: choices,
            transport: links.transport,
            afterStart: links.startPairing,
            agentLocality: agent.descriptor.locality,
            presentConsent: LiveServices.presentConsent,
            notifier: UserNotificationsNotifier.shared,
            localNetwork: BonjourLocalNetworkPrompter(),
            // Calendar (lane C) and location (lane D) are real; photos stays
            // simulated while Swap photos is behind its flag.
            permissions: [LocationPermissionAccess(location: places.location), LiveServices.calendarPermission, DebugPermissionAccess(permission: .photoLibrary)],
            cardsFile: try? .standard("peer-cards.json"),
            notesFile: try? .standard("plan-notes.json")
        )
    }

    /// Fakes only, built synchronously for SwiftUI previews.
    static func previewServices(friends: [String]) -> AppServices {
        let peers = InMemoryPairedPeerStore(friends.map { randomPeer(nickname: $0) })
        let demo = randomPeer(nickname: "Demo phone")
        return AppServices(
            agent: scriptedAgent(),
            skillModel: scriptedSkillModel(),
            registry: SampleSkills.registry,
            makeSkills: { _ in SampleSkills.registry.descriptors.filter { SkillFlags.phase1_5.enabled.contains($0.id) }.map(ScriptedSkillService.init(descriptor:)) },
            interactions: InMemoryInteractionStore(),
            settings: InMemoryOwnerSettingsStore(),
            rules: InMemoryRulesStore(),
            peers: peers,
            pairing: PairingDirectory(
                localPeer: .random(),
                candidates: { [PairingCandidate(peer: demo.id, link: "Preview")] },
                pair: { _, nickname in
                    ScriptedPairingSession(code: "482 913", peer: try PairedPeer(publicKey: demo.publicKey, nickname: nickname, pairedAt: Timestamp(Date())))
                },
                paired: { peer in try? await peers.save(peer) }
            ),
            unpair: { id in try await peers.remove(id) },
            makePolicy: LiveServices.policy(peers: peers),
            transport: RecordingTransport(),
            agentLocality: .onDevice,
            presentConsent: LiveServices.presentConsent,
            notifier: PreviewSupport.SilentNotifier(),
            localNetwork: PreviewSupport.SilentPrompter(),
            permissions: SystemPermission.allCases.map(DebugPermissionAccess.init)
        )
    }

    static func randomPeer(nickname: String) -> PairedPeer {
        let key = try! IdentityPublicKey(bytes: Data((0..<IdentityPublicKey.byteCount).map { _ in UInt8.random(in: .min ... .max) }))
        return try! PairedPeer(publicKey: key, nickname: nickname, pairedAt: Timestamp(Date()))
    }

    /// Stands in for the rules model where it cannot run (the Simulator,
    /// ineligible phones).
    static func scriptedAgent() -> ScriptedAgentModel {
        ScriptedAgentModel(onInterpret: { _, context in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = context.timeZone
            let evening = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: context.now) ?? context.now
            return OwnerRules(constraints: try ConstraintSet([
                .time: [try Constraint(.within([try TimeSlot(start: evening, end: evening.addingTimeInterval(4 * 3600))]))],
                .budget: [try Constraint(.atMost(try MoneyAmount(minorUnits: 1500)))],
            ]))
        }, onDecide: { _ in .accept })
    }

    /// Stands in for lane B's SkillModel until it merges: routes by a few
    /// words and reads the first word as the activity, "tonight" as 7 to 11
    /// PM, and "near" or "nearby" as nearby. Deliberately simple: it shows
    /// the composer working, not the model's quality.
    static func scriptedSkillModel() -> ScriptedSkillModel {
        ScriptedSkillModel(
            onRoute: { text, skills in
                let lower = text.lowercased()
                let wanted: SkillID = if lower.contains("time") || lower.contains("when") || lower.contains("schedule") { .findATime }
                    else if lower.contains("place") || lower.contains("where") { .pickAPlace }
                    else { .downFor }
                return skills.contains { $0.id == wanted } ? wanted : nil
            },
            onIntent: { text, skill in
                let words = text.lowercased().split { !$0.isLetter }.map(String.init)
                let skip: Set = ["find", "a", "time", "with", "for", "tonight", "tomorrow", "next", "week", "whoever", "s", "free", "nothing", "far", "near", "nearby", "pick", "place", "the", "to", "go", "get"]
                var constraints: [IssueKey: [Constraint]] = [:]
                let slots = Set(skill.intent.slots.map(\.issue))
                if slots.contains(.activity), let first = words.first(where: { !skip.contains($0) && $0.count > 2 }), let keyword = try? Keyword(first) {
                    constraints[.activity] = [try Constraint(.prefers(liked: [keyword], avoided: []))]
                }
                if slots.contains(.time) {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = .current
                    let now = Date()
                    let day = words.contains("tomorrow") ? now.addingTimeInterval(86_400) : now
                    let start = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: day) ?? now
                    let range = words.contains("week") ? (start, start.addingTimeInterval(6 * 86_400)) : (max(start, now), start.addingTimeInterval(4 * 3600))
                    if range.1 > range.0 { constraints[.time] = [try Constraint(.within([try TimeSlot(start: range.0, end: range.1)]))] }
                }
                if slots.contains(.place), words.contains(where: { ["near", "nearby", "far"].contains($0) }) {
                    constraints[.place] = [try Constraint(.prefers(liked: [try Keyword("nearby")], avoided: []))]
                }
                let names = words.indices.compactMap { index in index > 0 && words[index - 1] == "with" && words[index] != "whoever" ? words[index] : nil }
                return ParsedIntent(constraints: try ConstraintSet(constraints), mentionedNames: names)
            },
            onProposal: { _ in throw AgentModelError.unsupported }
        )
    }

    // MARK: Developer controls

    /// A friend who exists only in this session, with a card that runs
    /// every Phase 1.5 skill.
    func addSampleFriend(to app: AppModel) async {
        sampleCount += 1
        let friend = Self.randomPeer(nickname: ["Maya", "Jake", "Priya", "Leo", "Sam", "Ana"][(sampleCount - 1) % 6])
        try? await overlay.save(friend)
        await app.friends?.load()
        guard let me = localPeer else { return }
        let card = AgentCard.forBuild(skills: registry.advertised(in: SkillSettings(flags: .phase1_5)), usesPSI: true, locality: .onDevice)
        if let hello = try? Envelope(conversation: ConversationID(), sender: friend.id, recipient: me, sequence: 0, sentAt: Timestamp(Date()), body: .hello(card)) {
            app.cards.handle(.message(hello))
        }
    }

    static func sampleTerms(start: Date = Date().addingTimeInterval(3600)) throws -> Terms {
        try Terms([
            .time: .slots([try TimeSlot(start: start, end: start.addingTimeInterval(2 * 3600))]),
            .activity: .keywords([try Keyword("boba")]),
            .budget: .amount(try MoneyAmount(minorUnits: 1200)),
        ])
    }

    static func sampleDisclosure(to peer: PeerID, start: Date, roster: [PeerID] = []) throws -> Disclosure {
        var items = [
            DisclosedItem(category: .psi, issue: .time, value: .slots([try TimeSlot(start: start, end: start.addingTimeInterval(4 * 3600))])),
            DisclosedItem(category: .terms, issue: .activity, value: .keywords([try Keyword("boba")])),
        ]
        if !roster.isEmpty { items.append(DisclosedItem(category: .terms, issue: .people, value: .peers(roster))) }
        return Disclosure(recipient: peer, recipientModel: .onDevice, items: items)
    }

    /// Sends a sample proposal to the first friend through the app's Outbox:
    /// lane G's policy, the consent sheet, and the audit log.
    func sendSample(through app: AppModel) async -> String {
        guard let outbox = app.outbox else { return "This build has no Outbox." }
        guard let friend = app.friends?.friends.first, let proposal = try? Proposal(round: 0, terms: Self.sampleTerms(start: sampleStart)) else {
            return "Add a friend first."
        }
        do {
            try await outbox.send(.propose(proposal), to: friend.id, conversation: ConversationID())
            return "Sent to \(friend.nickname)."
        } catch {
            return SendFailureMessage.text(for: error) ?? "Failed: \(error)"
        }
    }
}

/// Moves the scripted skills through the lifecycle the way a skill service
/// would: a request gets a proposal after a moment, "I'm in" becomes a
/// plan, and Developer buttons play a friend's side.
@MainActor
@Observable
final class DemoDriver {
    let me: PeerID
    let services: [ScriptedSkillService]
    private var seenStarts: Set<InteractionID> = []
    private var seenAnswers = 0
    private var requests: [InteractionID: (SkillRequest, ScriptedSkillService)] = [:]
    private var revisions: [InteractionID: UInt32] = [:]
    var autoPropose = true
    private var loop: Task<Void, Never>?

    init(me: PeerID, services: [ScriptedSkillService]) {
        self.me = me
        self.services = services
    }

    func run() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.step()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func step() async {
        for service in services {
            for request in await service.started where !seenStarts.contains(request.interaction) {
                seenStarts.insert(request.interaction)
                requests[request.interaction] = (request, service)
                // An invitation's starter is never told a friend is down
                // before that friend says I'm in (issue #95), so a scripted
                // Down for... invitation waits for the Developer buttons.
                let invitation = request.intent.skill.id == .downFor && request.intent.mode == .invite
                if autoPropose, !invitation {
                    try? await Task.sleep(for: .seconds(2))
                    await propose(request.interaction)
                }
            }
        }
        var answers: [(InteractionID, OwnerAnswer, ScriptedSkillService)] = []
        for service in services { answers += await service.answers.map { ($0.0, $0.1, service) } }
        for (id, answer, service) in answers.dropFirst(seenAnswers) {
            switch answer {
            case .accept(let revision): await confirm(id, revision: revision)
            // A skill reports the pass when ending cannot reveal it (ADR 0011
            // amendment 16); the scripted one does so at once.
            case .pass: await service.emit(.lifecycle(id, .ownerPassed))
            case .reply: break
            }
        }
        seenAnswers = answers.count
    }

    /// The agents agreed: a proposal card from the request's own chips.
    func propose(_ id: InteractionID) async {
        guard let (request, service) = requests[id] else { return }
        let revision = (revisions[id] ?? 0) + 1
        revisions[id] = revision
        var terms: [IssueKey: IssueValue] = [:]
        for (issue, list) in request.intent.rules.constraints.constraints {
            for constraint in list {
                switch constraint.rule {
                case .prefers(let liked, _) where !liked.isEmpty: terms[issue] = .keywords(Array(liked.prefix(1)))
                case .within(let slots): if let first = slots.sorted().first {
                    let start = first.start
                    terms[issue] = .slots([(try? TimeSlot(start: start, end: min(first.end, start.addingTimeInterval(2 * 3600)))) ?? first])
                }
                default: break
                }
            }
        }
        if request.intent.skill.id == .pickAPlace, let place = try? PlaceChoice(name: PlaceName("Boba Guys"), coordinate: Coordinate(latitude: 37.7599, longitude: -122.4214)) {
            terms[.place] = .places([place])
        }
        guard let terms = try? Terms(terms) else { return }
        await service.emit(.lifecycle(id, .proposalReady(SkillProposal(revision: revision, participants: [me] + request.participants, terms: terms))))
    }

    /// Everyone said yes: the plan.
    private func confirm(_ id: InteractionID, revision: UInt32) async {
        guard let (request, service) = requests[id] else { return }
        try? await Task.sleep(for: .seconds(1))
        await service.emit(.lifecycle(id, .everyoneConfirmed(revision: revision)))
        let people = Array(([me] + request.participants).prefix(ProtocolLimits.maxAttendees))
        guard let attendees = try? Attendees(people) else { return }
        var activity: Keyword?
        var time: TimeSlot?
        for constraint in request.intent.rules.constraints.constraints[.activity] ?? [] {
            if case .prefers(let liked, _) = constraint.rule { activity = activity ?? liked.first }
        }
        for constraint in request.intent.rules.constraints.constraints[.time] ?? [] {
            if case .within(let slots) = constraint.rule, let first = slots.sorted().first {
                time = time ?? (try? TimeSlot(start: first.start, end: min(first.end, first.start.addingTimeInterval(2 * 3600))))
            }
        }
        if request.intent.skill.id == .pickAPlace, let place = try? PlaceChoice(name: PlaceName("Boba Guys"), coordinate: Coordinate(latitude: 37.7599, longitude: -122.4214)) {
            await service.emit(.produced(id, .placeChoice(place)))
            return
        }
        if let plan = try? Plan(origin: request.conversation, attendees: attendees, activity: activity ?? (try? Keyword("hang out")), time: time) {
            await service.emit(.produced(id, .plan(plan)))
        }
    }

    /// The live requests this phone sent, newest first.
    var live: [InteractionID] { Array(requests.keys) }

    func nobodyUp(_ id: InteractionID) async {
        await requests[id]?.1.emit(.lifecycle(id, .noAgreement))
    }

    /// A friend's Down for… lines up with the owner's: both are down.
    func friendIsDownToo(_ friend: PeerID) async {
        guard let service = services.first(where: { $0.descriptor.id == .downFor }) else { return }
        let id = InteractionID()
        let conversation = ConversationID()
        await service.emit(.incoming(id, conversation: conversation, from: friend, chainedFrom: nil))
        let start = Date().addingTimeInterval(3 * 3600)
        guard let slot = try? TimeSlot(start: start, end: start.addingTimeInterval(2 * 3600)),
              let terms = try? Terms([.activity: .keywords([try Keyword("tacos")]), .time: .slots([slot])]) else { return }
        let request = SkillRequest(interaction: id, conversation: conversation,
                                   intent: SkillIntent(skill: service.descriptor.ref, rules: OwnerRules(constraints: (try? ConstraintSet([.activity: [try Constraint(.prefers(liked: [try Keyword("tacos")], avoided: []))], .time: [try Constraint(.within([slot]))]])) ?? .empty), audience: .picked([friend]), mode: .askQuietly, expiresAt: Timestamp(start)),
                                   participants: [friend])
        requests[id] = (request, service)
        revisions[id] = 1
        await service.emit(.lifecycle(id, .proposalReady(SkillProposal(revision: 1, participants: [me, friend], terms: terms))))
    }
}

/// Stands in for lanes C, D, and E's access APIs: "the system alert"
/// answers yes, or no when Developer says so. It never shows a real alert,
/// because the purpose strings arrive with those lanes.
struct DebugPermissionAccess: PermissionAccess {
    let permission: SystemPermission

    private var key: String { "dev.permission.\(permission.rawValue)" }

    func status() async -> PermissionStatus {
        switch UserDefaults.standard.string(forKey: key) {
        case "granted": .granted
        case "denied": .denied
        default: .notDetermined
        }
    }

    func request() async -> PermissionStatus {
        let deny = UserDefaults.standard.bool(forKey: DebugHarness.denyPermissionsKey)
        UserDefaults.standard.set(deny ? "denied" : "granted", forKey: key)
        return deny ? .denied : .granted
    }

    static func reset() {
        for permission in SystemPermission.allCases { UserDefaults.standard.removeObject(forKey: "dev.permission.\(permission.rawValue)") }
    }
}

/// Runs a whole Down for… headless when the app is launched with
/// `-starlingSelfTestLifecycle YES` and prints the outcome: two sample
/// friends, a request from New, every consent sheet approved, the demo
/// proposal accepted, and the plan. Evidence that the composer, the
/// coordinator, the consent sheet, and Home work together where the
/// Simulator cannot be tapped through.
@MainActor
enum LifecycleSelfTest {
    static func runIfRequested(app: AppModel, harness: DebugHarness) async {
        guard UserDefaults.standard.bool(forKey: "starlingSelfTestLifecycle") else { return }
        await app.start()
        harness.driver?.run()
        await harness.addSampleFriend(to: app)
        await harness.addSampleFriend(to: app)
        let approver = Task {
            while !Task.isCancelled {
                if let request = app.consent.current { app.consent.answer(.approved, to: request.id) }
                if app.permissions.pending != nil { app.permissions.proceed() }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { approver.cancel() }

        app.composer.text = "boba tonight with whoever's free"
        await app.composer.understand()
        print("SELFTEST understood: \(app.composer.skillChip ?? "none") \(app.composer.chips)")
        guard let id = await app.composer.send() else {
            print("SELFTEST NOT SENT: \(app.composer.notice ?? app.composer.blocker ?? "unknown")")
            return
        }
        for _ in 0..<100 where app.lifecycle.interaction(id)?.state != .proposed { try? await Task.sleep(for: .milliseconds(100)) }
        print("SELFTEST home: \(app.home.headline); needs you \(app.home.needsYou.map(\.status))")
        guard let revision = app.lifecycle.interaction(id)?.proposalRevision else {
            print("SELFTEST NO PROPOSAL; state \(String(describing: app.lifecycle.interaction(id)?.state))")
            return
        }
        await app.lifecycle.answer(id, with: .accept(proposal: revision))
        for _ in 0..<100 where app.lifecycle.interaction(id)?.plan == nil { try? await Task.sleep(for: .milliseconds(100)) }
        let final = app.lifecycle.interaction(id)
        print("SELFTEST PLAN: state \(String(describing: final?.state)); \(final.map { app.planDetail($0).title } ?? "none"); history \(final?.history.map { "\($0.state)" } ?? []); dropped \(app.lifecycle.dropped.count)")
    }
}

/// The Keychain friends plus friends that exist only in this Debug session,
/// which are never written to the Keychain. Lane E1's authority commits real
/// pairings to the Keychain part.
actor OverlayPairedPeerStore: PairedPeerStore {
    private let base: any PairedPeerStore
    private let overlay: InMemoryPairedPeerStore

    init(base: any PairedPeerStore, overlay: InMemoryPairedPeerStore) {
        self.base = base
        self.overlay = overlay
    }

    func all() async throws -> [PairedPeer] {
        let session = try await overlay.all()
        let ids = Set(session.map(\.id))
        return (try await base.all()).filter { !ids.contains($0.id) } + session
    }

    func peer(for id: PeerID) async throws -> PairedPeer? {
        if let peer = try await overlay.peer(for: id) { return peer }
        return try await base.peer(for: id)
    }

    func save(_ peer: PairedPeer) async throws {
        if try await overlay.peer(for: peer.id) != nil { try await overlay.save(peer) } else { try await base.save(peer) }
    }

    func remove(_ id: PeerID) async throws {
        if try await overlay.peer(for: id) != nil { try await overlay.remove(id) } else { try await base.remove(id) }
    }
}

/// Fakes-backed models for SwiftUI previews.
@MainActor
enum PreviewSupport {
    static func app(friends: [String] = ["Maya", "Jake"]) -> AppModel {
        AppModel(services: DebugHarness.previewServices(friends: friends))
    }

    struct SilentNotifier: PlanNotifier {
        func requestAuthorization() async -> Bool { true }
        func post(_ notice: LifecycleNotice) async {}
    }

    struct SilentPrompter: LocalNetworkPrompter {
        func prompt() async {}
    }
}
#endif
