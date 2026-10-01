import Foundation
import StarlingCore

/// A Pick a place proposal card's words: a headline, which the model may
/// write, and the place line, which only code writes.
public struct PlaceProposalCopy: Hashable, Sendable {
    /// "Boba with Maya and Jake"
    public let headline: String
    /// "Boba Guys at 8:30 PM?"
    public let detail: String
}

/// Proposal wording for Pick a place (ADR 0016, 0017, 0231). Venue names
/// are bounded display text a friend may have chosen, so they never enter
/// a prompt: the model writes the headline from facts with the place
/// removed, and code puts the name in the detail line. Lane A shows a Pick
/// a place card through `proposal(_:model:)`, never by passing these facts
/// to `SkillModel.proposalText` itself.
public enum PickAPlaceCopy {
    /// The longest headline accepted from the model.
    public static let maxHeadlineCharacters = 80

    /// The facts the model may see: everything but the venue.
    public static func modelFacts(_ facts: ProposalFacts) -> ProposalFacts {
        ProposalFacts(skill: facts.skill, friendNames: facts.friendNames, activity: facts.activity, time: facts.time, place: nil, timeZone: facts.timeZone)
    }

    /// The facts for a proposal card, with friends named by the owner's own
    /// nicknames (never by anything a friend sent).
    public static func facts(for proposal: SkillProposal, me: PeerID, nickname: (PeerID) -> String?, timeZone: TimeZone) -> ProposalFacts {
        let place: PlaceName? = if case .places(let places)? = proposal.terms[.place] { places.first?.name } else { nil }
        let activity: Keyword? = if case .keywords(let words)? = proposal.terms[.activity] { words.first } else { nil }
        let time: TimeSlot? = if case .slots(let slots)? = proposal.terms[.time] { slots.first } else { nil }
        let names = proposal.participants.filter { $0 != me }.map { nickname($0) ?? "a friend" }
        return ProposalFacts(skill: PickAPlaceSkill.ref, friendNames: names, activity: activity, time: time, place: place, timeZone: timeZone)
    }

    /// The card's words. Uses the model for the headline when it gives one
    /// line of plain text, and the template otherwise.
    public static func proposal(_ facts: ProposalFacts, model: (any SkillModel)?, locale: Locale = .autoupdatingCurrent) async -> PlaceProposalCopy {
        var headline = templateHeadline(facts)
        if let model, let written = try? await model.proposalText(modelFacts(facts)).value {
            let line = written.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty, line.count <= maxHeadlineCharacters, !line.contains(where: \.isNewline) { headline = line }
        }
        return PlaceProposalCopy(headline: headline, detail: detail(facts, locale: locale))
    }

    /// "Boba with Maya and Jake", or "A place with Maya and Jake".
    public static func templateHeadline(_ facts: ProposalFacts) -> String {
        let who = names(facts.friendNames)
        guard let activity = facts.activity?.value else { return who.isEmpty ? "A place for you" : "A place with \(who)" }
        let what = activity.prefix(1).uppercased() + activity.dropFirst()
        return who.isEmpty ? String(what) : "\(what) with \(who)"
    }

    /// "Boba Guys at 8:30 PM?", or "Boba Guys?".
    public static func detail(_ facts: ProposalFacts, locale: Locale = .autoupdatingCurrent) -> String {
        let place = facts.place?.rawValue ?? "Somewhere new"
        guard let time = facts.time else { return "\(place)?" }
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = facts.timeZone
        style.locale = locale
        return "\(place) at \(time.start.formatted(style))?"
    }

    static func names(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}
