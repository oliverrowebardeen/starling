import Foundation
import StarlingCore

// Doubles for the Phase 1.5 skill interfaces, so lanes build the shell,
// skills, chaining, and red-team scenarios before the real packages land.

/// The four Phase 1.5 skills as descriptors, with the mockups' plan
/// wording (ADR 0017). Fixtures: each skill package defines its real
/// descriptor and may start from these.
public enum SampleSkills {
    public static let downFor = try! SkillDescriptor(
        ref: SkillRef(.downFor, SkillVersion(1)),
        wording: SkillWording(
            name: "Down for…", summary: "See who's up for something", startAction: "See who's up for it",
            acceptAction: "I'm in", declineAction: "Not tonight", declineNote: "If you pass, they just won't see it."
        ),
        buildingBlock: .mutualReveal,
        topicsUsed: [.time, .activity, .place, .budget],
        topicsRequired: [.time, .activity],
        accepts: [.timeSlot],
        produces: [.plan],
        intent: IntentSchema(slots: [
            IntentSlot(.activity, required: true, hint: "what they want to do, such as boba or a walk"),
            IntentSlot(.time, required: false, hint: "when, such as tonight after 7"),
            IntentSlot(.place, required: false, hint: "where or how far, such as nearby"),
            IntentSlot(.budget, required: false, hint: "the most they want to spend"),
        ]),
        sendModes: [.askQuietly, .invite]
    )

    public static let findATime = try! SkillDescriptor(
        ref: SkillRef(.findATime, SkillVersion(1)),
        wording: SkillWording(
            name: "Find a time", summary: "Agree on when", startAction: "Find a time",
            acceptAction: "That works", declineAction: "Not then", declineNote: "If you pass, they just won't see it."
        ),
        buildingBlock: .privateQuery,
        // Calendar details are read on the phone only; a group plan sends
        // its roster under people.
        topicsUsed: [.time, .activity, .people, .calendarDetails],
        topicsRequired: [.time],
        permissions: [.calendarFullAccess],
        produces: [.timeSlot, .plan],
        intent: IntentSchema(slots: [
            IntentSlot(.time, required: true, hint: "the range to look in, such as next week"),
            IntentSlot(.activity, required: false, hint: "what it is for, such as stats"),
        ])
    )

    public static let pickAPlace = try! SkillDescriptor(
        ref: SkillRef(.pickAPlace, SkillVersion(1)),
        wording: SkillWording(
            name: "Pick a place", summary: "Agree on where", startAction: "Find a place",
            acceptAction: "Sounds good", declineAction: "Somewhere else", declineNote: "If you pass, they just won't see it."
        ),
        buildingBlock: .privateAggregation,
        // Budget, diet, and location judge venues on the phone (ADR 0019).
        topicsUsed: [.place, .location, .budget, .diet],
        topicsRequired: [.place],
        permissions: [.locationWhenInUse],
        accepts: [.plan, .timeSlot],
        produces: [.placeChoice],
        intent: IntentSchema(slots: [
            IntentSlot(.place, required: false, hint: "the kind of place or area, such as near Franklin"),
            IntentSlot(.budget, required: false, hint: "the most they want to spend"),
            IntentSlot(.diet, required: false, hint: "what they can't eat"),
        ])
    )

    /// Flagged off in Phase 1.5: proves the time-triggered chain hook only.
    public static let swapPhotos = try! SkillDescriptor(
        ref: SkillRef(.swapPhotos, SkillVersion(1)),
        wording: SkillWording(
            name: "Swap photos", summary: "Share photos from a plan", startAction: "Swap photos",
            acceptAction: "Share", declineAction: "Not these", declineNote: "If you pass, they just won't see it."
        ),
        buildingBlock: .matchedExchange,
        topicsUsed: [.photos],
        topicsRequired: [.photos],
        permissions: [.photoLibrary],
        accepts: [.plan],
        produces: [],
        intent: IntentSchema(slots: [IntentSlot(.photos, required: false, hint: "which photos, such as from tonight")],
                             asksForAudience: false, asksForExpiry: false),
        chainTrigger: .afterPlanEnds
    )

    public static let all = [downFor, findATime, pickAPlace, swapPhotos]

    public static let registry = try! SkillRegistry(all)
}

/// A deterministic `SkillModel` driven by closures. Every task throws
/// `AgentModelError.unsupported` until scripted.
public struct ScriptedSkillModel: SkillModel {
    public var descriptor: ModelDescriptor
    public var onRoute: @Sendable (String, [SkillDescriptor]) async throws -> SkillID?
    public var onIntent: @Sendable (String, SkillDescriptor) async throws -> ParsedIntent
    public var onProposal: @Sendable (ProposalFacts) async throws -> String

    public init(
        descriptor: ModelDescriptor = ModelDescriptor(identifier: "fake.scripted.skills", locality: .onDevice, contextSize: 4096),
        onRoute: @escaping @Sendable (String, [SkillDescriptor]) async throws -> SkillID? = { _, _ in throw AgentModelError.unsupported },
        onIntent: @escaping @Sendable (String, SkillDescriptor) async throws -> ParsedIntent = { _, _ in throw AgentModelError.unsupported },
        onProposal: @escaping @Sendable (ProposalFacts) async throws -> String = { _ in throw AgentModelError.unsupported }
    ) {
        self.descriptor = descriptor
        self.onRoute = onRoute
        self.onIntent = onIntent
        self.onProposal = onProposal
    }

    public func route(_ utterance: String, among skills: [SkillDescriptor]) async throws -> ModelResult<SkillID?> {
        ModelResult(value: try await onRoute(utterance, skills), usage: nil, latency: .zero)
    }

    public func intent(from utterance: String, for skill: SkillDescriptor, now: Date, timeZone: TimeZone) async throws -> ModelResult<ParsedIntent> {
        ModelResult(value: try await onIntent(utterance, skill), usage: nil, latency: .zero)
    }

    public func proposalText(_ facts: ProposalFacts) async throws -> ModelResult<String> {
        ModelResult(value: try await onProposal(facts), usage: nil, latency: .zero)
    }
}

/// An in-memory `InteractionStore` for tests and previews.
public actor InMemoryInteractionStore: InteractionStore {
    private var items: [InteractionID: Interaction]

    public init(_ interactions: [Interaction] = []) {
        items = Dictionary(interactions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func all() async throws -> [Interaction] { items.values.sorted { $0.createdAt < $1.createdAt } }
    public func interaction(_ id: InteractionID) async throws -> Interaction? { items[id] }
    public func interaction(conversation: ConversationID) async throws -> Interaction? {
        items.values.first { $0.conversation == conversation }
    }
    public func save(_ interaction: Interaction) async throws { items[interaction.id] = interaction }
    public func remove(_ id: InteractionID) async throws { items[id] = nil }
}

/// A `SkillService` that records what the shell asked of it and emits
/// whatever events a test or preview pushes with `emit(_:)`.
public actor ScriptedSkillService: SkillService {
    public nonisolated let descriptor: SkillDescriptor
    public nonisolated let events: AsyncStream<SkillEvent>
    private let continuation: AsyncStream<SkillEvent>.Continuation

    public private(set) var started: [SkillRequest] = []
    public private(set) var answers: [(InteractionID, OwnerAnswer)] = []
    public private(set) var withdrawn: [InteractionID] = []
    public private(set) var handled: [InboxEvent] = []

    public init(descriptor: SkillDescriptor) {
        self.descriptor = descriptor
        (events, continuation) = AsyncStream.makeStream(of: SkillEvent.self)
    }

    public func emit(_ event: SkillEvent) { continuation.yield(event) }

    public func start(_ request: SkillRequest) async throws { started.append(request) }
    public func answer(_ interaction: InteractionID, with answer: OwnerAnswer) async throws { answers.append((interaction, answer)) }
    public func withdraw(_ interaction: InteractionID) async { withdrawn.append(interaction) }
    public private(set) var restored: [Interaction] = []

    public func handle(_ event: InboxEvent) async { handled.append(event) }
    public func restore(_ interactions: [Interaction]) async { restored = interactions }
    public func shutdown() async { continuation.finish() }
}
