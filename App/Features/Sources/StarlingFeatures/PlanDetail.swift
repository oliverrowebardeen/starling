import Foundation
import Observation
import StarlingChaining
import StarlingCore

/// A hand-off the owner made from a plan, for "How this came together".
public struct HandOffRecord: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case calendar, messages, directions
    }

    public let kind: Kind
    public let at: Timestamp
    /// The plan's revision when the hand-off was made, so a later change
    /// can offer it again ("Update in Calendar", ADR 0022). Nil in records
    /// from before plans could change, which count as revision 0.
    public let revision: UInt32?

    public init(kind: Kind, at: Timestamp, revision: UInt32? = nil) {
        self.kind = kind
        self.at = at
        self.revision = revision
    }
}

/// A friend linked to a contact on this phone, for Message the group
/// (ADR 0018 decision 2). Chosen with the system contact picker, which
/// needs no Contacts permission. Never sent and never part of pairing data.
public struct ContactLink: Hashable, Sendable, Codable {
    public let contactID: String
    /// The contact's name as it appears in Contacts, shown in Friends.
    public let name: String
    public let phone: String

    public init(contactID: String, name: String, phone: String) {
        self.contactID = contactID
        self.name = name
        self.phone = phone
    }
}

/// What the owner keeps about plans and friends on this phone beyond the
/// interactions themselves: hand-offs made, contact links, cards passed
/// whose skill has not ended them yet (ADR 0011 amendment 16), and which
/// one-to-one interactions came from one quiet ask (amendment 17). One JSON
/// file (ADR 0204), never sent.
@MainActor
@Observable
public final class PlanNotes {
    struct Document: Codable {
        var handOffs: [String: [HandOffRecord]] = [:]
        var contactLinks: [String: ContactLink] = [:]
        var passed: [String]? = nil
        var requestGroups: [String: String]? = nil
    }

    public private(set) var handOffs: [InteractionID: [HandOffRecord]] = [:]
    public private(set) var contactLinks: [PeerID: ContactLink] = [:]
    public private(set) var passed: Set<InteractionID> = []
    /// Quiet asks' one-to-one interactions by request, for Home only.
    public private(set) var requestGroups: [InteractionID: UUID] = [:]
    private let file: JSONFile?
    private let now: @Sendable () -> Date

    public init(file: JSONFile?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.now = now
    }

    public func load() {
        guard let file, let document = try? file.read(Document.self) else { return }
        for (key, records) in document.handOffs {
            if let uuid = UUID(uuidString: key) { handOffs[InteractionID(uuid)] = records }
        }
        for (hex, link) in document.contactLinks {
            if let peer = try? PeerID(hex: hex) { contactLinks[peer] = link }
        }
        passed = Set((document.passed ?? []).compactMap { UUID(uuidString: $0).map(InteractionID.init) })
        for (key, value) in document.requestGroups ?? [:] {
            if let id = UUID(uuidString: key), let group = UUID(uuidString: value) { requestGroups[InteractionID(id)] = group }
        }
    }

    public func setRequestGroups(_ groups: [InteractionID: UUID]) {
        guard groups != requestGroups else { return }
        requestGroups = groups
        save()
    }

    public func setPassed(_ ids: Set<InteractionID>) {
        guard ids != passed else { return }
        passed = ids
        save()
    }

    public func record(_ kind: HandOffRecord.Kind, for plan: InteractionID, revision: UInt32? = nil) {
        handOffs[plan, default: []].append(HandOffRecord(kind: kind, at: Timestamp(now()), revision: revision))
        save()
    }

    public func link(_ friend: PeerID, to contact: ContactLink) {
        contactLinks[friend] = contact
        save()
    }

    public func unlink(_ friend: PeerID) {
        guard contactLinks.removeValue(forKey: friend) != nil else { return }
        save()
    }

    private func save() {
        guard let file else { return }
        try? file.write(Document(
            handOffs: Dictionary(uniqueKeysWithValues: handOffs.map { ($0.key.description, $0.value) }),
            contactLinks: Dictionary(uniqueKeysWithValues: contactLinks.map { ($0.key.hex, $0.value) }),
            passed: passed.map(\.description).sorted(),
            requestGroups: Dictionary(uniqueKeysWithValues: requestGroups.map { ($0.key.description, $0.value.uuidString) })
        ))
    }
}

/// An event for `EKEventEditViewController`, pre-filled from a plan (ADR
/// 0018 decision 1). EventKitUI adds it with no calendar permission.
public struct CalendarDraft: Hashable, Sendable {
    public let title: String
    public let start: Date
    public let end: Date
    public let location: String?
}

/// Messages pre-filled for the group (ADR 0018 decision 2).
public struct MessageDraft: Hashable, Sendable {
    /// Phone numbers of friends linked to a contact on this phone.
    public let recipients: [String]
    /// Friends with no link, for the owner to add in Messages.
    public let unlinked: [PeerID]
    public let body: String
}

/// One step in "How this came together".
public struct TimelineEntry: Hashable, Sendable, Identifiable {
    public let id: String
    public let tag: String
    public let text: String
    public let at: Date?
    public let isDone: Bool
}

/// A plan's It's a plan screen and detail (mockups "It's a plan" and "Plan
/// detail"), from its chain of interactions alone.
public struct PlanDetail: Hashable, Sendable {
    public let root: Interaction
    public let chain: [Interaction]
    /// The plan with the latest agreed place applied.
    public let plan: Plan?
    public let title: String
    /// "Tonight at 8:30 PM · Boba Guys"
    public let subtitle: String
    /// "You, Maya and Jake"
    public let people: String
    /// "All 3 of you said yes"
    public let saidYes: String
    public let timeline: [TimelineEntry]
    /// What left the phone across the chain, in plain words.
    public let shared: [String]
    /// What the chain's skills could use but never sent. Empty when a send's
    /// items are unknown: then nothing can be said to have stayed.
    public let kept: [String]
    /// False when the policy could not say what some send included (Core
    /// v2.1, `EgressRecord.itemsUnknown`).
    public let auditIsComplete: Bool
    public let calendar: CalendarDraft?
    /// The plan changed after it was added to the calendar: offer "Update
    /// in Calendar" (ADR 0022 decision 8).
    public let calendarIsOutdated: Bool
    public let message: MessageDraft
    public let place: PlaceChoice?

    /// - Parameters:
    ///   - unconfirmed: `EgressRecorder.unconfirmedConversations`: logs that
    ///     may be missing a send.
    ///   - auditUnknown: the recorder's journal could not be read at launch,
    ///     or has not been recovered yet, so no log can be vouched for.
    @MainActor
    public init(root: Interaction, all: [Interaction], words: InteractionWords, notes: PlanNotes,
                unconfirmed: Set<ConversationID> = [], auditUnknown: Bool = false) {
        // Lane E's timeline: the plan, the owner's links, and friends'
        // requests grouped under it by their checked hints (ADR 0240).
        let timeline = PlanTimeline(for: root.id, in: all, registry: words.registry, unconfirmed: unconfirmed)
        let ids = timeline?.entries.map(\.id) ?? [root.id]
        let chain = ids.compactMap { id in all.first { $0.id == id } }
        self.root = root
        self.chain = chain.isEmpty ? [root] : chain

        // The plan as stored. A place result reaches it only through the
        // coordinator, with lane E's ChainPlanner.parent(_:updatedBy:),
        // which applies it at the parent's next revision and ignores
        // anything older; nothing here writes a place into it (Codex review
        // of PR #118).
        let plan = root.plan
        self.plan = plan
        place = plan?.place

        let peers = plan?.attendees.peers ?? root.participants
        title = words.summary(root)?.title ?? "Your plan"
        people = words.everyone(peers)
        let count = Set(peers + (words.localPeer.map { [$0] } ?? [])).count
        saidYes = count <= 2 ? "You both said yes" : "All \(count) of you said yes"
        var line: [String] = []
        if let time = plan?.time { line.append(words.chips.start(time)) }
        if let place = plan?.place { line.append(place.name.rawValue) }
        subtitle = line.joined(separator: " · ")

        self.timeline = Self.timeline(self.chain, entries: timeline?.entries ?? [], words: words, notes: notes)
        let whatLeft = timeline?.whatLeft ?? WhatLeftYourPhone(interactions: self.chain, registry: words.registry, unconfirmed: unconfirmed)
        auditIsComplete = !auditUnknown && whatLeft.unconfirmed.isEmpty
        (shared, kept) = Self.audit(whatLeft, complete: auditIsComplete, words: words)

        let added = notes.handOffs[root.id]?.last { $0.kind == .calendar }
        calendarIsOutdated = added.map { ($0.revision ?? 0) < (plan?.revision ?? 0) } ?? false
        if let plan, let time = plan.time {
            calendar = CalendarDraft(title: title, start: time.start, end: time.end, location: plan.place?.name.rawValue)
        } else {
            calendar = nil
        }
        let friends = peers.filter { $0 != words.localPeer }
        var body = "It's a plan"
        if let activity = plan?.activity { body += ": \(activity.value)" }
        if let time = plan?.time { body += ", \(words.chips.start(time).lowercasedFirstLetter)" }
        if let place = plan?.place { body += ", \(place.name.rawValue)" }
        message = MessageDraft(
            recipients: friends.compactMap { notes.contactLinks[$0]?.phone },
            unlinked: friends.filter { notes.contactLinks[$0] == nil },
            body: body + "."
        )
    }

    @MainActor
    static func timeline(_ chain: [Interaction], entries: [PlanTimeline.Entry], words: InteractionWords, notes: PlanNotes) -> [TimelineEntry] {
        let basis = chain.first?.plan
        var rows: [TimelineEntry] = chain.compactMap { link in
            guard let summary = words.summary(link) else { return nil }
            // Change the plan: what changed, who left, or "The plan stays as
            // it was"; a friend's suggestion that closed is left off.
            if link.skill.id == .changePlan, link.id != chain.first?.id {
                guard let text = words.changeTimeline(link, basis: basis) else { return nil }
                return TimelineEntry(id: link.id.description, tag: summary.skill.wording.name, text: text, at: link.updatedAt.date,
                                     isDone: link.state.isFinal || link.state == .planned)
            }
            // A place step on the plan that found nobody up changed nothing,
            // and the plan still stands (ADR 0022 decision 4).
            if link.skill.id == .pickAPlace, link.id != chain.first?.id, link.state == .ended(.nobodyUp) {
                return TimelineEntry(id: link.id.description, tag: summary.skill.wording.name, text: InteractionWords.staysAsItWas,
                                     at: link.updatedAt.date, isDone: true)
            }
            let entry = entries.first { $0.id == link.id }
            // An after-plan-ends link the owner opted into, still waiting.
            if let startsAfter = entry?.startsAfter {
                return TimelineEntry(id: link.id.description, tag: summary.skill.wording.name, text: "Starts when the plan ends", at: startsAfter, isDone: false)
            }
            let agreed = link.state == .planned || link.state == .done
            return TimelineEntry(
                id: link.id.description, tag: summary.skill.wording.name,
                text: agreed ? Self.agreement(link, summary: summary, words: words) : summary.status,
                at: link.updatedAt.date, isDone: agreed
            )
        }
        for record in notes.handOffs[chain.first?.id ?? InteractionID()] ?? [] {
            let (tag, text): (String, String) = switch record.kind {
            case .calendar: ("Calendar", "Added to your calendar")
            case .messages: ("Messages", "Messaged the group")
            case .directions: ("Maps", "Opened directions")
            }
            rows.append(TimelineEntry(id: "\(record.kind.rawValue)-\(record.at.millisecondsSince1970)", tag: tag, text: text, at: record.at.date, isDone: true))
        }
        return rows.sorted { ($0.at ?? .distantFuture) < ($1.at ?? .distantFuture) }
    }

    /// "All 3 down for boba", "Boba Guys · 3 of 3 agreed".
    static func agreement(_ link: Interaction, summary: InteractionSummary, words: InteractionWords) -> String {
        let count = link.plan?.attendees.peers.count ?? link.proposal?.participants.count ?? link.participants.count + 1
        switch link.skill.id {
        case .downFor:
            let activity = words.activity(of: link) ?? "it"
            return count <= 2 ? "Both down for \(activity)" : "All \(count) down for \(activity)"
        case .pickAPlace:
            let place = link.artifacts.lazy.compactMap { if case .placeChoice(let choice) = $0 { choice.name.rawValue } else { nil } }.first
            return "\(place ?? "A place") · \(count) of \(count) agreed"
        case .findATime:
            if let time = link.plan?.time ?? link.artifacts.lazy.compactMap({ if case .timeSlot(let slot) = $0 { slot } else { nil } }).first {
                return "Agreed on \(words.chips.start(time).lowercasedFirstLetter)"
            }
            return "Agreed on a time"
        default:
            return "It's a plan"
        }
    }

    /// Shared versus kept on the phone, from lane E's `WhatLeftYourPhone`
    /// over the egress logs (the consent sheet's own items, ADR 0011
    /// decision 5). Nothing is claimed kept unless every log is complete.
    static func audit(_ whatLeft: WhatLeftYourPhone, complete: Bool, words: InteractionWords) -> (shared: [String], kept: [String]) {
        var shared: [String] = []
        for topic in whatLeft.shared {
            let texts = topic.values.isEmpty
                ? [topic.topic.label]
                : topic.values.flatMap { describe(DisclosedItem(category: .terms, issue: topic.topic.issues.sorted().first, value: $0), words: words) }
            for text in texts where !shared.contains(text) { shared.append(text) }
        }
        guard complete else { return (shared, []) }
        var kept: [String] = []
        for item in whatLeft.kept {
            let text: String = switch item {
            case .topic(let topic): topic.label
            case .permission(.calendarFullAccess): "Calendar details"
            case .permission(.locationWhenInUse): "Exact location"
            case .permission(.photoLibrary): "Your photo library"
            }
            if !kept.contains(text) { kept.append(text) }
        }
        return (shared, kept)
    }

    static func describe(_ item: DisclosedItem, words: InteractionWords) -> [String] {
        guard let value = item.value else {
            return item.category == .agentCard ? [] : [item.issue.map(words.formatter.issueName) ?? "Plan details"]
        }
        switch value {
        case .keywords(let list): return list.map { $0.value.capitalizedFirstLetter }
        case .slots(let slots): return slots.sorted().map(words.chips.slot)
        case .places(let places): return places.map(\.name.rawValue)
        case .peers: return ["Who's coming"]
        case .amount(let amount): return ["\(words.formatter.issueName(item.issue ?? .budget)) \(words.formatter.money(amount))"]
        case .flag, .count: return ["\(words.formatter.issueName(item.issue ?? .partySize)): \(words.formatter.value(value))"]
        }
    }
}

/// Siri and Shortcuts' "What's my next plan?" (ADR 0018 decision 4).
public enum NextPlanAnswer {
    public static func text(_ interactions: [Interaction], words: InteractionWords, now: Date) -> String {
        let upcoming = interactions
            .filter { $0.state == .planned && words.isVisible($0) }
            .compactMap { item in item.plan?.time.map { (item, $0) } }
            .filter { $0.1.end > now }
            .sorted { $0.1.start < $1.1.start }
        guard let (item, time) = upcoming.first, let summary = words.summary(item) else { return "You have no plans coming up." }
        var text = "\(summary.title), \(words.chips.start(time).lowercasedFirstLetter)"
        if let place = item.plan?.place { text += ", at \(place.name.rawValue)" }
        return text + "."
    }
}
