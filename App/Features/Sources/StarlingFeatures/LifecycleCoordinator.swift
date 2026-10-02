import Foundation
import Observation
import os
import StarlingChaining
import StarlingCore

/// An event the coordinator did not apply, kept for the Developer section
/// (Debug builds) and the unified log. Dropping is the safe answer to a
/// late, replayed, or out-of-order event: the interaction stays as it was.
public struct DroppedEvent: Hashable, Sendable, Identifiable {
    public enum Reason: Hashable, Sendable {
        case invalidTransition(InvalidTransition)
        case staleProposal(StaleProposal)
        case staleQuestion(StaleQuestion)
        case unknownConsentRequest(UnknownConsentRequest)
        /// No interaction with this ID on the phone.
        case unknownInteraction
        /// An incoming request for an ID or conversation already on the phone.
        case duplicateIncoming
        /// A service reported an interaction that belongs to another skill.
        case wrongSkill
        /// An artifact for an interaction that already ended.
        case afterEnd
        /// Any other error from `Interaction.apply`; none exists today.
        case other(String)
    }

    public let id = UUID()
    public let interaction: InteractionID?
    public let skill: SkillID
    public let event: String
    public let reason: Reason
    public let at: Date

    public static func == (lhs: DroppedEvent, rhs: DroppedEvent) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Why `LifecycleCoordinator.start(_:chain:)` did not send a request.
public enum StartRefusal: Error, Hashable, Sendable {
    /// No registered service runs the skill.
    case notInThisBuild
    /// None of the chosen friends runs the skill at a compatible version.
    case unsupported
    /// Required topics are set to Never (ADR 0014).
    case blockedByPrivacy(Set<PrivacyTopic>)
    /// The service could not start; the interaction ended as failed.
    case failed(String)
    /// The request could not be saved on the phone, so it was not sent.
    case notSaved
}

/// The one lifecycle coordinator (ADR 0011 decision 7, ADR 0201).
///
/// - It consumes every `SkillService`'s events and applies them to the
///   `Interaction` records, which only it writes, then persists them.
/// - The owner's own steps (sending, I'm in, pass, answering a question,
///   withdrawing, and each consent sheet) are applied here first, then
///   forwarded to the service, so a tap on a stale card never reaches it.
/// - Events that do not apply (`InvalidTransition`, `StaleProposal`,
///   `StaleQuestion`, `UnknownConsentRequest`, and unknown interactions)
///   are dropped and logged; the record stays unchanged.
/// - At launch it hands each service its live interactions with
///   `restore(_:)` before any Inbox event reaches the services.
@MainActor
@Observable
public final class LifecycleCoordinator {
    public static let maxDropped = 100

    /// Every interaction on the phone, oldest first.
    public private(set) var interactions: [Interaction] = []
    /// Newest last, at most `maxDropped`.
    public private(set) var dropped: [DroppedEvent] = []
    public private(set) var isLoaded = false
    /// Cards the owner passed on whose skill has not reported the pass yet
    /// (ADR 0011 amendment 16). Hidden on this phone at once; the record is
    /// unchanged, and nothing is retired, until the service reports
    /// `ownerPassed`, so friends see the same traffic as for no answer.
    public private(set) var passed: Set<InteractionID> = []
    /// Called whenever `passed` changes, so the app can keep it across a
    /// relaunch.
    public var onPassedChange: @MainActor (Set<InteractionID>) -> Void = { _ in }
    /// The quiet ask each one-to-one interaction came from (ADR 0011
    /// amendment 17), so Home can show them under one request. A local ID
    /// for display only; it is never sent.
    public private(set) var requestGroups: [InteractionID: UUID] = [:]
    /// Called whenever `requestGroups` changes, so the app can keep it
    /// across a relaunch.
    public var onRequestGroupsChange: @MainActor ([InteractionID: UUID]) -> Void = { _ in }
    /// A plain sentence when the store could not be read or written.
    public private(set) var notice: String?

    /// Called after every applied change with the record before and after,
    /// for notifications. Not called for dropped events.
    public var onChange: @MainActor (_ before: Interaction?, _ after: Interaction) -> Void = { _, _ in }
    /// Called when an interaction reaches a final state, so the consent
    /// sheets still queued for its conversation are withdrawn.
    public var onFinished: @MainActor (_ interaction: InteractionID, _ conversation: ConversationID) -> Void = { _, _ in }
    /// Runs once at launch, after the interactions are loaded and before any
    /// service is restored. The app recovers lane E's egress journal here, so
    /// no service can schedule a send, and no audit can be read as complete,
    /// before the sends the journal still holds are back (P15-E 4.1, privacy
    /// review of PR #73).
    public var beforeRestore: @MainActor () async -> Void = {}

    /// How long an ended interaction is still handed to `restore(_:)`, so a
    /// service can ignore a late retry instead of reopening it (ADR 0011
    /// amendment 15).
    public static let recentlyEnded: TimeInterval = 24 * 3600

    public let registry: SkillRegistry
    private let services: [SkillID: any SkillService]
    private let store: any InteractionStore
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.oliverrowebardeen.starling", category: "lifecycle")
    private var loops: [Task<Void, Never>] = []
    private var starting: Task<Void, Never>?
    private var dirty: [InteractionID] = []
    private var writer: Task<Void, Never>?
    /// Interactions whose latest save failed, so a caller that must know its
    /// change is on disk (the egress sink) can tell.
    private var unsaved: Set<InteractionID> = []
    /// Progress a service reported while its interaction was suspended on a
    /// consent sheet, in order, applied once the step resumes (amendment 15).
    private var deferred: [InteractionID: [InteractionEvent]] = [:]
    private var ticker: Task<Void, Never>?

    public init(registry: SkillRegistry, services: [any SkillService], store: any InteractionStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.registry = registry
        var byID: [SkillID: any SkillService] = [:]
        for service in services { byID[service.descriptor.id] = service }
        self.services = byID
        self.store = store
        self.now = now
    }

    public var skillsInBuild: Set<SkillID> { Set(services.keys) }

    public func service(for skill: SkillID) -> (any SkillService)? { services[skill] }

    public func interaction(_ id: InteractionID) -> Interaction? {
        interactions.first { $0.id == id }
    }

    /// Conversations that can still resume: live interactions and those
    /// that ended within the restore window. Their sent sequence numbers
    /// must be kept.
    public var resumableConversations: Set<ConversationID> {
        let cutoff = Timestamp(now().addingTimeInterval(-Self.recentlyEnded))
        return Set(interactions.filter { !$0.state.isFinal || $0.updatedAt >= cutoff }.map(\.conversation))
    }

    public func interaction(conversation: ConversationID) -> Interaction? {
        interactions.first { $0.conversation == conversation }
    }

    // MARK: Launch

    /// Loads the store, runs `beforeRestore`, restores each service's live
    /// interactions, then starts consuming every service's events. Runs
    /// once; later calls wait for the first.
    public func start() async {
        if starting == nil {
            starting = Task { await self.load() }
        }
        await starting?.value
    }

    private func load() async {
        do {
            interactions = try await store.all()
        } catch {
            interactions = []
            notice = "Your plans couldn't be read, so Home starts empty. Nothing was sent."
            logger.error("store unreadable: \(String(describing: error), privacy: .public)")
        }
        if let file = store as? FileInteractionStore, await file.quarantined != nil {
            notice = "Your earlier plans couldn't be read, so Home starts empty. Nothing was sent."
        }
        // A sheet does not survive the app: every request still open was
        // never answered and nothing was sent for it (amendment 15).
        for item in interactions where !item.pendingConsents.isEmpty {
            for request in item.pendingConsents.sorted() {
                apply(.consentCancelled(request: request), to: item.id, reportedAs: nil, skill: item.skill.id)
            }
        }
        await beforeRestore()
        // Groups only for interactions still on the phone.
        let known = Set(interactions.map(\.id))
        if requestGroups.keys.contains(where: { !known.contains($0) }) {
            requestGroups = requestGroups.filter { known.contains($0.key) }
            onRequestGroupsChange(requestGroups)
        }
        // A pass the skill reported while the app was closed has ended its
        // interaction; nothing else is hidden any more.
        let open = Set(interactions.filter { !$0.state.isFinal }.map(\.id))
        if !passed.isSubset(of: open) {
            passed.formIntersection(open)
            onPassedChange(passed)
        }
        let cutoff = Timestamp(now().addingTimeInterval(-Self.recentlyEnded))
        for (id, service) in services {
            let live = interactions.filter { $0.skill.id == id && (!$0.state.isFinal || $0.updatedAt >= cutoff) }
            await service.restore(live)
        }
        for service in services.values {
            let descriptor = service.descriptor
            loops.append(Task { [weak self] in
                for await event in service.events {
                    await self?.handle(event, from: descriptor)
                }
            })
        }
        isLoaded = true
        tick()
        // Plans end while the app runs too, not only at launch.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.tick()
            }
        }
    }

    /// Every Inbox event goes to every service, once restore has run.
    public func route(_ event: InboxEvent) async {
        await start()
        for service in services.values { await service.handle(event) }
    }

    public func shutdown() async {
        ticker?.cancel()
        ticker = nil
        for loop in loops { loop.cancel() }
        loops = []
        for service in services.values { await service.shutdown() }
        await flush()
    }

    // MARK: Service events

    /// Applies one event a service reported. Internal so tests can apply
    /// events without waiting on a stream.
    func handle(_ event: SkillEvent, from skill: SkillDescriptor) async {
        switch event {
        case .incoming(let id, let conversation, let peer, let chainedFrom):
            guard interaction(id) == nil, interaction(conversation: conversation) == nil else {
                return drop(event, id, skill.id, .duplicateIncoming)
            }
            var invitee = Interaction(id: id, conversation: conversation, skill: skill.ref, role: .invitee, participants: [peer], createdAt: Timestamp(now()))
            // `chainedFrom` is a hint for the timeline only (ADR 0012
            // decision 6, P15-E request 4.3): kept only when it names a plan
            // on this phone the sender was in, and never a ChainLink, a
            // start, a permission, or a schedule.
            if let parent = IncomingChain.timelineParent(chainedFrom: chainedFrom, sender: peer, interactions: interactions) {
                try? invitee.setFriendChainHint(parent)
            }
            insert(invitee)
        case .lifecycle(let id, let lifecycle):
            guard let current = interaction(id) else { return drop(event, id, skill.id, .unknownInteraction) }
            guard current.skill.id == skill.id else { return drop(event, id, skill.id, .wrongSkill) }
            if case .awaitingConsent = current.state, Self.waitsForConsent(lifecycle) {
                deferred[id, default: []].append(lifecycle)
                return
            }
            apply(lifecycle, to: id, reportedAs: event, skill: skill.id)
        case .produced(let id, let artifact):
            guard var current = interaction(id) else { return drop(event, id, skill.id, .unknownInteraction) }
            guard current.skill.id == skill.id else { return drop(event, id, skill.id, .wrongSkill) }
            if case .ended = current.state { return drop(event, id, skill.id, .afterEnd) }
            let before = current
            current.record(artifact)
            replace(current, before: before)
        }
    }

    // MARK: Owner steps

    /// Groups from an earlier launch. Call before `start()`.
    public func restoreRequestGroups(_ groups: [InteractionID: UUID]) {
        requestGroups.merge(groups) { current, _ in current }
    }

    /// Sends a request the owner composed. A quiet ask is one-to-one (ADR
    /// 0011 amendment 17): one initiator interaction per friend, each in its
    /// own conversation with the same intent, started separately, so no
    /// friend's messages depend on another's answers. They share a local
    /// group ID for Home only. Anything else is one interaction. Returns
    /// the interactions started, the first being `request.interaction`.
    @discardableResult
    public func send(_ request: SkillRequest, chain: ChainLink? = nil, settings: SkillSettings) async throws(StartRefusal) -> [InteractionID] {
        guard request.intent.mode == .askQuietly, request.participants.count > 1 else {
            return [try await start(request, chain: chain, settings: settings)]
        }
        let siblings = request.participants.enumerated().map { index, friend in
            SkillRequest(
                interaction: index == 0 ? request.interaction : InteractionID(),
                conversation: index == 0 ? request.conversation : ConversationID(),
                intent: request.intent, participants: [friend], inputs: request.inputs, chainedFrom: request.chainedFrom
            )
        }
        // Loaded first, so the launch's pruning cannot drop the new group.
        await start()
        // Grouped before any starts, so Home never shows them apart.
        let group = UUID()
        for sibling in siblings { requestGroups[sibling.interaction] = group }
        onRequestGroupsChange(requestGroups)
        var started: [InteractionID] = []
        var firstRefusal: StartRefusal?
        for sibling in siblings {
            do {
                started.append(try await start(sibling, chain: chain, settings: settings))
            } catch {
                switch error {
                // The same for every friend: stop at the first.
                case .notInThisBuild, .blockedByPrivacy:
                    if started.isEmpty { forgetGroup(siblings); throw error }
                    return started
                default:
                    firstRefusal = firstRefusal ?? error
                }
            }
        }
        if started.isEmpty, let firstRefusal { forgetGroup(siblings); throw firstRefusal }
        return started
    }

    /// Puts a later request with the same friends under a quiet ask's group:
    /// the invitation to make its pair plans one plan (P15-B request 9).
    public func addToRequestGroup(_ id: InteractionID, group: UUID) {
        guard interaction(id) != nil, requestGroups.values.contains(group) else { return }
        requestGroups[id] = group
        onRequestGroupsChange(requestGroups)
    }

    /// Drops the group of a quiet ask none of whose interactions started and
    /// none of which is on the phone.
    private func forgetGroup(_ siblings: [SkillRequest]) {
        var changed = false
        for sibling in siblings where interaction(sibling.interaction) == nil {
            changed = requestGroups.removeValue(forKey: sibling.interaction) != nil || changed
        }
        if changed { onRequestGroupsChange(requestGroups) }
    }

    /// Sends a request the owner composed. Creates the initiator
    /// interaction, applies `started`, then starts the service. A request
    /// that cannot run is recorded as ended with its reason and refused.
    @discardableResult
    public func start(_ request: SkillRequest, chain: ChainLink? = nil, settings: SkillSettings) async throws(StartRefusal) -> InteractionID {
        await start()
        let skill = request.intent.skill
        guard let service = services[skill.id] else { throw .notInThisBuild }
        var item = Interaction(
            id: request.interaction, conversation: request.conversation, skill: skill, role: .initiator,
            participants: request.participants, createdAt: Timestamp(now()), chain: chain
        )
        if case .blockedByPrivacy(let topics) = registry.availability(of: skill.id, in: settings) {
            try? item.apply(.blockedByPrivacy, at: Timestamp(now()))
            insert(item)
            throw .blockedByPrivacy(topics)
        }
        if request.participants.isEmpty {
            try? item.apply(.unsupported, at: Timestamp(now()))
            insert(item)
            throw .unsupported
        }
        try? item.apply(.started, at: Timestamp(now()))
        // The record must be on disk before the skill sends anything, so a
        // request that went out can always be restored or withdrawn after a
        // crash. A save that fails refuses the start: nothing is sent and
        // nothing is shown (ADR 0011 amendment 13, re-review of PR #54).
        do {
            try await store.save(item)
        } catch {
            logger.error("start refused, save failed: \(String(describing: error), privacy: .public)")
            throw .notSaved
        }
        insert(item)
        do {
            try await service.start(request)
        } catch {
            apply(.failed, to: item.id, reportedAs: nil, skill: skill.id)
            throw .failed(String(describing: error))
        }
        return item.id
    }

    /// Cards passed in an earlier launch whose skill had not reported the
    /// pass yet. Call before `start()`.
    public func restorePassed(_ ids: Set<InteractionID>) {
        passed.formUnion(ids)
    }

    /// The owner's answer on a card. Applied here first: an acceptance of
    /// anything but the current proposal revision, or a reply to anything
    /// but the pending question, is dropped and never reaches the service.
    /// A pass only hides the card and goes to the service, which reports
    /// `ownerPassed` when ending cannot reveal it (ADR 0011 amendment 16).
    /// Returns whether it was applied.
    @discardableResult
    public func answer(_ id: InteractionID, with answer: OwnerAnswer) async -> Bool {
        guard let current = interaction(id), let service = services[current.skill.id] else { return false }
        if case .pass = answer { return await pass(current, service: service) }
        let event: InteractionEvent = switch answer {
        case .accept(let revision): .ownerAccepted(revision: revision)
        case .pass: .ownerPassed
        case .reply(let question, _): .ownerAnswered(question: question)
        }
        guard apply(event, to: id, reportedAs: nil, skill: current.skill.id) else { return false }
        do {
            try await service.answer(id, with: answer)
        } catch {
            logger.error("service refused an answer for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        return true
    }

    private func pass(_ current: Interaction, service: any SkillService) async -> Bool {
        // A pass must still apply to the record as it stands, so a tap on a
        // stale card is dropped as before; the record itself is not changed.
        var probe = current
        do {
            try probe.apply(.ownerPassed, at: Timestamp(now()))
        } catch {
            drop("\(InteractionEvent.ownerPassed)", current.id, current.skill.id, .other(String(describing: error)))
            return false
        }
        guard passed.insert(current.id).inserted else { return true }
        onPassedChange(passed)
        do {
            try await service.answer(current.id, with: .pass)
        } catch {
            // The skill did not take the pass: show the card again so the
            // owner can answer it.
            logger.error("service refused a pass for \(current.id, privacy: .public): \(String(describing: error), privacy: .public)")
            passed.remove(current.id)
            onPassedChange(passed)
            return false
        }
        return true
    }

    /// The owner withdrew a request. Friends learn nothing beyond "no plan".
    public func withdraw(_ id: InteractionID) async {
        guard let current = interaction(id), let service = services[current.skill.id] else { return }
        guard apply(.withdrawn, to: id, reportedAs: nil, skill: current.skill.id) else { return }
        await service.withdraw(id)
    }

    // MARK: Consent and egress

    /// The interaction a send belongs to: the one the service named
    /// (`Disclosure.interaction`, from `OutboundContext.interaction`) when
    /// it is in that conversation or belongs to the disclosure's skill,
    /// otherwise the conversation's own. A Down for... member sends in the
    /// starter's conversation, never its own request's, so the named
    /// interaction is trusted when its skill matches (P15-B request 8). The
    /// ID comes from this phone's service, never from a peer.
    public func owner(interaction id: InteractionID?, skill: SkillRef? = nil, conversation: ConversationID) -> Interaction? {
        if let id, let named = interaction(id) {
            if named.conversation == conversation { return named }
            if let skill, named.skill.id == skill.id { return named }
        }
        return interaction(conversation: conversation)
    }

    /// A consent sheet is about to ask about a send. Suspends the
    /// interaction under a new request ID, which it returns, or nil when no
    /// interaction owns the send (the link layer's hello) or it cannot be
    /// suspended now.
    public func consentRequested(interaction id: InteractionID? = nil, skill: SkillRef? = nil, conversation: ConversationID) -> UInt32? {
        guard let current = owner(interaction: id, skill: skill, conversation: conversation), !current.state.isFinal else { return nil }
        let request = current.consentWatermark &+ 1
        guard request > current.consentWatermark else { return nil }
        return apply(.consentNeeded(request: request), to: current.id, reportedAs: nil, skill: current.skill.id) ? request : nil
    }

    /// The owner answered that sheet. Approval resumes the interrupted step
    /// once no other request is open; anything else ends it declined.
    /// Returns whether the answer applied. An approval that does not apply
    /// (the interaction ended, or the request is unknown or was already
    /// closed) must not let the send go out.
    @discardableResult
    public func consentAnswered(interaction id: InteractionID? = nil, skill: SkillRef? = nil, conversation: ConversationID, request: UInt32, approved: Bool) -> Bool {
        guard let current = owner(interaction: id, skill: skill, conversation: conversation) else { return false }
        return apply(approved ? .consentGiven(request: request) : .ownerPassed, to: current.id, reportedAs: nil, skill: current.skill.id)
    }

    /// The send waiting on that sheet was cancelled: nobody answered and
    /// nothing was sent, so the step resumes without recording an approval
    /// or a pass (ADR 0011 amendment 15).
    public func consentCancelled(interaction id: InteractionID? = nil, skill: SkillRef? = nil, conversation: ConversationID, request: UInt32) {
        guard let current = owner(interaction: id, skill: skill, conversation: conversation) else { return }
        apply(.consentCancelled(request: request), to: current.id, reportedAs: nil, skill: current.skill.id)
    }

    /// Whether the send's interaction has ended, so nothing more may be sent
    /// for it, even with a remembered approval.
    public func isFinished(interaction id: InteractionID? = nil, skill: SkillRef? = nil, conversation: ConversationID) -> Bool {
        owner(interaction: id, skill: skill, conversation: conversation)?.state.isFinal ?? false
    }

    /// Progress that waits while a consent sheet is up. Ends apply at once.
    static func waitsForConsent(_ event: InteractionEvent) -> Bool {
        switch event {
        case .ownerNeeded, .proposalReady, .everyoneConfirmed: true
        default: false
        }
    }

    /// Every registered service, for app-level upkeep such as retrying
    /// retirements that failed.
    public var allServices: [any SkillService] { Array(services.values) }

    /// Acts on one of lane E's after-plan-ends decisions (P15-E request
    /// 4.5). Checked against the stored link right before acting, in the
    /// same main-actor step, so a link the owner opted out of, or one that
    /// already started, is left alone. A start is saved before the service
    /// hears of it, like any other start (ADR 0011 amendment 13).
    public func applyScheduled(_ scheduled: ScheduledChain, rules: OwnerRules, expiresAt: Timestamp) async {
        let current = interaction(scheduled.link.id)
        guard scheduled.isCurrent(current), let link = current else { return }
        switch scheduled {
        case .cancel(_, let event):
            apply(event, to: link.id, reportedAs: nil, skill: link.skill.id)
        case .start(let due):
            guard let service = services[link.skill.id] else {
                apply(.failed, to: link.id, reportedAs: nil, skill: link.skill.id)
                return
            }
            // Through the one writer, so a later opt-out can never be
            // overwritten on disk by this start. Nothing is sent unless the
            // start is saved (ADR 0011 amendment 13). The saved link keeps
            // only the plan's people as they stand now (P15-E 4.5).
            var started = link
            started.setParticipants(due.link.participants)
            do {
                try started.apply(.started, at: Timestamp(now()))
            } catch {
                drop("\(InteractionEvent.started)", link.id, link.skill.id, .other(String(describing: error)))
                return
            }
            replace(started, before: link)
            await flush()
            if unsaved.contains(link.id) {
                logger.error("scheduled start not saved; not sent")
                apply(.failed, to: link.id, reportedAs: nil, skill: link.skill.id)
                return
            }
            // The owner may have withdrawn it while it saved.
            guard let saved = interaction(link.id), !saved.state.isFinal else { return }
            do {
                try await service.start(due.request(rules: rules, expiresAt: expiresAt))
            } catch {
                apply(.failed, to: link.id, reportedAs: nil, skill: link.skill.id)
            }
        }
    }

    /// Saves a change made from another interaction, such as lane E moving a
    /// plan to the place its chained link agreed on. Only for an interaction
    /// already on the phone; its state machine is untouched.
    public func update(_ changed: Interaction) {
        guard let current = interaction(changed.id), current != changed,
              current.state == changed.state, current.conversation == changed.conversation else { return }
        replace(changed, before: current)
    }

    /// Ends plans whose time has passed (`planEnded`). The app calls this at
    /// launch and when it comes to the foreground.
    public func tick() {
        let time = now()
        for item in interactions where item.state == .planned {
            guard let end = item.plan?.endsAt, end <= time else { continue }
            apply(.planEnded, to: item.id, reportedAs: nil, skill: item.skill.id)
        }
    }

    // MARK: Applying and saving

    /// Applies one lifecycle event. Returns false and logs a drop if it
    /// does not apply.
    @discardableResult
    private func apply(_ event: InteractionEvent, to id: InteractionID, reportedAs original: SkillEvent?, skill: SkillID) -> Bool {
        guard var current = interaction(id) else {
            drop(original.map { "\($0)" } ?? "\(event)", id, skill, .unknownInteraction)
            return false
        }
        let before = current
        do {
            try current.apply(event, at: Timestamp(now()))
        } catch {
            let reason: DroppedEvent.Reason = switch error {
            case let error as InvalidTransition: .invalidTransition(error)
            case let error as StaleProposal: .staleProposal(error)
            case let error as StaleQuestion: .staleQuestion(error)
            case let error as UnknownConsentRequest: .unknownConsentRequest(error)
            default: .other(String(describing: error))
            }
            drop(original.map { "\($0)" } ?? "\(event)", id, skill, reason)
            return false
        }
        replace(current, before: before)
        return true
    }

    private func insert(_ item: Interaction) {
        interactions.append(item)
        markDirty(item.id)
        onChange(nil, item)
    }

    private func replace(_ item: Interaction, before: Interaction) {
        guard let index = interactions.firstIndex(where: { $0.id == item.id }) else { return }
        interactions[index] = item
        markDirty(item.id)
        onChange(before, item)
        if item.state.isFinal, passed.remove(item.id) != nil { onPassedChange(passed) }
        if item.state.isFinal, !before.state.isFinal {
            deferred[item.id] = nil
            onFinished(item.id, item.conversation)
        } else if case .awaitingConsent = before.state, !isSuspended(item) {
            drainDeferred(item.id)
        }
    }

    private func isSuspended(_ item: Interaction) -> Bool {
        if case .awaitingConsent = item.state { true } else { false }
    }

    /// Applies progress held during a suspension, in order, stopping if one
    /// suspends the interaction again.
    private func drainDeferred(_ id: InteractionID) {
        while let next = deferred[id]?.first {
            deferred[id]?.removeFirst()
            if deferred[id]?.isEmpty == true { deferred[id] = nil }
            guard let current = interaction(id) else { return }
            apply(next, to: id, reportedAs: nil, skill: current.skill.id)
            if let after = interaction(id), isSuspended(after) || after.state.isFinal { return }
        }
    }

    private func drop(_ event: SkillEvent, _ id: InteractionID?, _ skill: SkillID, _ reason: DroppedEvent.Reason) {
        drop("\(event)", id, skill, reason)
    }

    private func drop(_ event: String, _ id: InteractionID?, _ skill: SkillID, _ reason: DroppedEvent.Reason) {
        dropped.append(DroppedEvent(interaction: id, skill: skill, event: event, reason: reason, at: now()))
        if dropped.count > Self.maxDropped { dropped.removeFirst(dropped.count - Self.maxDropped) }
        logger.debug("dropped \(skill, privacy: .public) event for \(id?.description ?? "none", privacy: .public): \(String(describing: reason), privacy: .private)")
    }

    /// Saves changed interactions one at a time, always the latest version,
    /// so a slow write can never land after a newer one.
    private func markDirty(_ id: InteractionID) {
        if !dirty.contains(id) { dirty.append(id) }
        guard writer == nil else { return }
        writer = Task { [weak self] in
            while let self, let next = self.nextDirty() {
                do {
                    try await self.store.save(next)
                    self.unsaved.remove(next.id)
                } catch {
                    self.unsaved.insert(next.id)
                    self.notice = "Starling couldn't save your latest plans. They'll be lost if the app closes."
                    self.logger.error("save failed: \(String(describing: error), privacy: .public)")
                }
            }
            self?.writer = nil
        }
    }

    private func nextDirty() -> Interaction? {
        while !dirty.isEmpty {
            let id = dirty.removeFirst()
            if let item = interaction(id) { return item }
        }
        writer = nil
        return nil
    }

    /// Waits until every change so far is saved.
    public func flush() async {
        while let writer { await writer.value }
    }
}

/// Lane E's `EgressRecorder` writes "What left your phone" through the
/// coordinator, the one place every interaction write goes (P15-E request
/// 4.1, ADR 0011 decision 7).
extension LifecycleCoordinator: EgressSink {
    /// Appends `record` to the conversation's interaction (a repeat for the
    /// same envelope is ignored) and returns once it is saved. Throws when
    /// the save failed, so the recorder keeps the send and retries it.
    public func appendEgress(_ record: EgressRecord, conversation: ConversationID) async throws -> Bool {
        try await appendEgress(record, interaction: nil, skill: nil, conversation: conversation)
    }

    /// As above, for the interaction the send named
    /// (`OutboundContext.interaction`) when it belongs to the send's skill,
    /// like a consent sheet (P15-B request 8): a Down for... member's send
    /// goes in the starter's conversation but belongs to its own request.
    public func appendEgress(_ record: EgressRecord, interaction id: InteractionID?, skill: SkillRef?, conversation: ConversationID) async throws -> Bool {
        guard var current = owner(interaction: id, skill: skill, conversation: conversation) else { return false }
        let before = current
        current.record(record)
        if current != before { replace(current, before: before) }
        await flush()
        if unsaved.contains(current.id) { throw EgressNotSaved() }
        return true
    }
}

/// The interaction holding an egress record could not be saved.
public struct EgressNotSaved: Error, Hashable, Sendable {}
