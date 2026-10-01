import FindATime
import Foundation
import PickAPlace
import StarlingCore

/// The status mark's pose, named like `StarlingDesign.MarkState`, which this
/// module cannot import (it never imports SwiftUI). The app maps one to the
/// other.
public enum StatusPose: String, Hashable, Sendable {
    case idle, searching, negotiating, match, noMatch
}

/// What Home and the cards say about one interaction, from the record and
/// the skill's descriptor alone, so any skill renders (ADR 0011).
public struct InteractionSummary: Hashable, Sendable, Identifiable {
    public var id: InteractionID { interaction.id }
    public let interaction: Interaction
    public let skill: SkillDescriptor
    /// "Down for boba", or the skill's name.
    public let tag: String
    /// "Boba with Maya and Jake", or the skill and who it is with.
    public let title: String
    /// One plain line about where it is: "Checking with 4 friends".
    public let status: String
    public let pose: StatusPose
}

/// Words for interactions, shared by Home, Friends, and plan detail.
public struct InteractionWords: Sendable {
    public let registry: SkillRegistry
    public let localPeer: PeerID?
    public let formatter: ValueFormatter
    public let chips: ChipFormatter
    private let names: @Sendable () -> [PeerID: String]

    public init(registry: SkillRegistry, localPeer: PeerID?, formatter: ValueFormatter, names: @escaping @Sendable () -> [PeerID: String], now: @escaping @Sendable () -> Date = { Date() }) {
        self.registry = registry
        self.localPeer = localPeer
        self.formatter = formatter
        self.names = names
        chips = ChipFormatter(values: formatter, now: now)
    }

    /// Whether Home and Friends may show this interaction at all.
    ///
    /// A friend's mutual-reveal request (Down for…) reaches this phone as an
    /// invitee interaction before anyone knows the interest is mutual.
    /// Showing it would tell the owner a friend asked, which is the one
    /// thing mutual reveal promises not to do (brief 2.6). It stays hidden
    /// until there is something for the owner to answer: a proposal (a
    /// quiet ask that turned out mutual), or a question (an Invite, which
    /// the friend's agent shows directly, ADR 0020). If neither ever comes,
    /// it stays hidden for good.
    public func isVisible(_ interaction: Interaction) -> Bool {
        guard let skill = registry.descriptor(for: interaction.skill.id) else { return interaction.role == .initiator }
        if skill.buildingBlock == .mutualReveal, interaction.role == .invitee,
           interaction.proposal == nil, interaction.questionWatermark == 0 { return false }
        return true
    }

    /// Friends' names for `peers`, without the owner, labeled with
    /// `RosterLabels` so a shared nickname is told apart. Titles and
    /// sentences call anyone not paired "someone you're not paired with";
    /// their full identifier belongs on the consent sheet and the
    /// interaction's people list, where the owner checks who it is.
    public func friendNames(_ peers: [PeerID]) -> [String] {
        let others = peers.filter { $0 != localPeer }
        let known = names()
        let labels = zip(others, RosterLabels.labels(for: others, friends: known)).compactMap { peer, label in
            known[peer] == nil ? nil : label
        }
        let unpaired = others.filter { known[$0] == nil }.count
        return labels + (unpaired == 0 ? [] : [unpaired == 1 ? Self.unpaired : "\(unpaired) people you're not paired with"])
    }

    public static let unpaired = "someone you're not paired with"

    /// The owner's own nickname for a paired friend, or nil.
    public func nickname(_ peer: PeerID) -> String? { names()[peer] }

    /// Whether `peer` is a paired friend now, for drawing their symbol.
    public func isFriend(_ peer: PeerID) -> Bool { names()[peer] != nil }

    /// "You, Maya and Jake".
    public func everyone(_ peers: [PeerID]) -> String {
        PermissionExplanation.names(["You"] + friendNames(peers))
    }

    public func summary(_ interaction: Interaction) -> InteractionSummary? {
        guard let skill = registry.descriptor(for: interaction.skill.id) else { return nil }
        return InteractionSummary(
            interaction: interaction, skill: skill, tag: tag(interaction, skill), title: title(interaction, skill),
            status: status(interaction, skill), pose: pose(interaction, skill)
        )
    }

    func tag(_ interaction: Interaction, _ skill: SkillDescriptor) -> String {
        if skill.id == .downFor, let activity = activity(of: interaction) { return "Down for \(activity)" }
        return skill.wording.name
    }

    /// The activity the plan or proposal agreed on, if any.
    public func activity(of interaction: Interaction) -> String? {
        if let activity = interaction.plan?.activity { return activity.value }
        if case .keywords(let words)? = interaction.proposal?.terms.values[.activity], let first = words.first { return first.value }
        return nil
    }

    func title(_ interaction: Interaction, _ skill: SkillDescriptor) -> String {
        let people = interaction.plan?.attendees.peers ?? interaction.proposal?.participants ?? interaction.participants
        let friends = PermissionExplanation.names(friendNames(people))
        if let activity = activity(of: interaction) { return "\(activity.capitalizedFirstLetter) with \(friends)" }
        return "\(skill.wording.name) with \(friends)"
    }

    func status(_ interaction: Interaction, _ skill: SkillDescriptor) -> String {
        let others = interaction.participants.filter { $0 != localPeer }.count
        let friends = others == 1 ? "1 friend" : "\(others) friends"
        switch interaction.state {
        case .drafting: return "Getting ready"
        case .negotiating:
            if interaction.role == .invitee { return "Your agent is on it" }
            return skill.buildingBlock == .mutualReveal ? "Checking with \(friends)" : "Waiting on \(others == 1 ? "1 agent" : "\(others) agents")"
        case .awaitingConsent: return "Check what leaves your phone"
        case .awaitingOwner: return question(interaction)
        case .proposed: return "Waiting for your answer"
        case .confirmed: return "You're in. Waiting on \(friends)"
        case .planned: return "It's a plan"
        case .done: return "Done"
        case .ended(let reason): return Self.ending(reason, skill)
        }
    }

    /// "Priya's agent asked when you're free" for a friend's question, or
    /// the agent's own question for the "Just ask me" fallback.
    public func question(_ interaction: Interaction) -> String {
        guard let question = interaction.pendingQuestion else { return "Your agent has a question" }
        let what: String = switch question.issue {
        case .time: "when you're free"
        case .place: "where works for you"
        case .activity: "what you're up for"
        default: "about \(formatter.issueName(question.issue).lowercased())"
        }
        if let asker = question.asker, asker != localPeer {
            return "\(friendNames([asker]).first ?? "A friend")'s agent asked \(what)"
        }
        return "Your agent asked \(what)"
    }

    static func ending(_ reason: EndReason, _ skill: SkillDescriptor) -> String {
        switch reason {
        case .declined: "You passed"
        case .nobodyUp: "No plan this time"
        case .expired: "Expired"
        case .withdrawn: "You took it back"
        case .failed: "Didn't go through"
        case .unsupported: "Friends' Starlings don't do this yet"
        case .blockedByPrivacy: "\(skill.wording.name) needs a topic you set to Never"
        }
    }

    func pose(_ interaction: Interaction, _ skill: SkillDescriptor) -> StatusPose {
        switch interaction.state {
        case .drafting, .awaitingConsent, .awaitingOwner, .proposed: .searching
        // Mutual reveal must not signal that anyone else is interested
        // (DESIGN.md section 3, brand request 1).
        case .negotiating: skill.buildingBlock == .mutualReveal ? .searching : .negotiating
        case .confirmed: .negotiating
        case .planned: .match
        case .done: .idle
        case .ended: .noMatch
        }
    }

    // MARK: Proposals

    /// The facts for a proposal sentence: typed values and the owner's own
    /// names for friends, never text a peer sent (ADR 0016).
    public func facts(_ interaction: Interaction) -> ProposalFacts? {
        guard let proposal = interaction.proposal else { return nil }
        let terms = proposal.terms.values
        var time: TimeSlot?
        if case .slots(let slots)? = terms[.time] { time = slots.sorted().first }
        var place: PlaceName?
        if case .places(let places)? = terms[.place] { place = places.first?.name }
        var activity: Keyword?
        if case .keywords(let words)? = terms[.activity] { activity = words.first }
        return ProposalFacts(
            skill: interaction.skill, friendNames: friendNames(proposal.participants),
            activity: activity ?? proposal.plan?.activity, time: time ?? proposal.plan?.time,
            place: place ?? proposal.plan?.place?.name, timeZone: formatter.timeZone
        )
    }

    /// The sentence without the model: "You, Maya and Jake are all down for
    /// boba." and "Boba Guys at 8:30 PM?". Skills ship their own template
    /// fallback (ADR 0016); this one covers any skill in the shell.
    public func template(_ facts: ProposalFacts) -> (headline: String, detail: String?) {
        // Lane C's own sentence already says when (P15-C request 2): "You
        // and Priya are free Thursday, October 8 at 4:00 PM for stats."
        if facts.skill.id == .findATime { return (FindATimeTemplate.sentence(facts, locale: formatter.locale), nil) }
        let people = PermissionExplanation.names(["You"] + facts.friendNames)
        let together = facts.friendNames.count == 1 ? "both" : "all"
        let headline: String = switch facts.skill.id {
        case .downFor: facts.activity.map { "\(people) are \(together) down for \($0.value)" } ?? "\(people) are \(together) up for it"
        case .pickAPlace: "A place for \(people)"
        default: "\(registry.descriptor(for: facts.skill.id)?.wording.name ?? "A plan") with \(people)"
        }
        let when = facts.time.map(chips.start)
        let detail: String? = switch (facts.place?.rawValue, when) {
        case let (place?, when?): "\(place), \(when.lowercasedFirstLetter)?"
        case let (place?, nil): "\(place)?"
        case let (nil, when?): "\(when)?"
        case (nil, nil): nil
        }
        return (headline, detail)
    }
}

/// Home (ADR 0015 decision 1, mockup "Home"): what needs the owner, what
/// the agent is working on, and plans coming up, with one line and the
/// status mark at the top.
public struct HomeContent: Hashable, Sendable {
    public let needsYou: [InteractionSummary]
    public let inProgress: [InteractionSummary]
    public let comingUp: [InteractionSummary]
    public let headline: String
    public let pose: StatusPose

    public init(_ interactions: [Interaction], words: InteractionWords) {
        let visible = interactions.filter(words.isVisible).compactMap(words.summary)
        needsYou = visible.filter { $0.interaction.state.homeSection == .needsYou }
            .sorted { $0.interaction.updatedAt > $1.interaction.updatedAt }
        inProgress = visible.filter { $0.interaction.state.homeSection == .inProgress }
            .sorted { $0.interaction.updatedAt > $1.interaction.updatedAt }
        comingUp = visible.filter { $0.interaction.state.homeSection == .comingUp }
            .sorted { Self.startsAt($0.interaction) < Self.startsAt($1.interaction) }

        if !inProgress.isEmpty {
            headline = inProgress.count == 1 ? "Your agent is working on 1 thing" : "Your agent is working on \(inProgress.count) things"
            pose = inProgress.contains { $0.pose == .negotiating } ? .negotiating : .searching
        } else if !needsYou.isEmpty {
            headline = needsYou.count == 1 ? "1 thing needs you" : "\(needsYou.count) things need you"
            pose = .searching
        } else if !comingUp.isEmpty {
            headline = comingUp.count == 1 ? "You have a plan coming up" : "You have \(comingUp.count) plans coming up"
            pose = .idle
        } else {
            headline = "Nothing in progress"
            pose = .idle
        }
    }

    public var isEmpty: Bool { needsYou.isEmpty && inProgress.isEmpty && comingUp.isEmpty }

    static func startsAt(_ interaction: Interaction) -> Date {
        interaction.plan?.time?.start ?? interaction.updatedAt.date
    }
}

/// What to tell the owner when an interaction changes, or nil for silence.
/// Notifications follow the same rule as Home: one-sided interest never
/// notifies anyone (brief 2.6), and endings are silent.
public struct LifecycleNotice: Hashable, Sendable {
    public let id: String
    public let title: String
    public let body: String

    public static func make(before: Interaction?, after: Interaction, words: InteractionWords) -> LifecycleNotice? {
        guard before?.state != after.state, words.isVisible(after), let summary = words.summary(after) else { return nil }
        let id = "interaction-\(after.id)"
        switch after.state {
        case .proposed:
            guard let facts = words.facts(after) else { return nil }
            let text = words.template(facts)
            return LifecycleNotice(id: id, title: text.headline, body: text.detail ?? "Open Starling to answer.")
        case .planned:
            return LifecycleNotice(id: id, title: "It's a plan", body: summary.title)
        case .awaitingOwner where after.role == .invitee:
            return LifecycleNotice(id: id, title: summary.tag, body: words.question(after))
        default:
            return nil
        }
    }
}

extension String {
    var lowercasedFirstLetter: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

/// Proposal sentences for cards: the model's when it is available (ADR
/// 0016), the template otherwise, cached per proposal revision. The text is
/// shown only on this phone and never sent.
@MainActor
@Observable
public final class ProposalTexts {
    private struct Key: Hashable {
        let interaction: InteractionID
        let revision: UInt32
    }

    private var written: [Key: String] = [:]
    private var asked: Set<Key> = []
    private let model: (any SkillModel)?

    public init(model: (any SkillModel)?) {
        self.model = model
    }

    /// The headline and detail for the interaction's current proposal.
    public func text(for interaction: Interaction, words: InteractionWords) -> (headline: String, detail: String?)? {
        if interaction.skill.id == .pickAPlace { return placeText(for: interaction, words: words) }
        guard let facts = words.facts(interaction), let revision = interaction.proposalRevision else { return nil }
        let template = words.template(facts)
        let key = Key(interaction: interaction.id, revision: revision)
        if let sentence = written[key] { return (sentence, template.detail) }
        if let model, !asked.contains(key) {
            asked.insert(key)
            Task {
                // A model that fails or is unavailable leaves the template.
                guard let sentence = try? await model.proposalText(facts).value else { return }
                let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.count <= 200 else { return }
                written[key] = trimmed
            }
        }
        return template
    }

    /// Pick a place's card, in lane D's words (P15-D request 5): the model
    /// may write the headline, but never sees the venue's name, which a
    /// friend may have chosen (ADR 0231).
    private func placeText(for interaction: Interaction, words: InteractionWords) -> (headline: String, detail: String?)? {
        guard let proposal = interaction.proposal, let revision = interaction.proposalRevision else { return nil }
        let facts = PickAPlaceCopy.facts(for: proposal, me: words.localPeer ?? PeerID.zero, nickname: words.nickname, timeZone: words.formatter.timeZone)
        let detail = PickAPlaceCopy.detail(facts, locale: words.formatter.locale)
        let key = Key(interaction: interaction.id, revision: revision)
        if let headline = written[key] { return (headline, detail) }
        if let model, !asked.contains(key) {
            asked.insert(key)
            Task {
                let copy = await PickAPlaceCopy.proposal(facts, model: model, locale: words.formatter.locale)
                written[key] = copy.headline
            }
        }
        return (PickAPlaceCopy.templateHeadline(facts), detail)
    }
}

extension PeerID {
    /// Stands in for "this phone" where no transport is in the build, so no
    /// friend is ever mistaken for the owner.
    static let zero = try! PeerID(bytes: Data(repeating: 0, count: PeerID.byteCount))
}
