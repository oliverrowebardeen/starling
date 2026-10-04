import Foundation
import StarlingCore

/// Change the plan (ADR 0022, ADR 0243): anyone in a confirmed plan can
/// suggest a new time, a new activity, or a friend to add, and the change
/// applies only when everyone else in the plan says yes. Anyone can leave
/// without asking. A new place or budget goes through Pick a place.
public enum ChangePlan {
    public static let descriptor = try! SkillDescriptor(
        ref: SkillRef(.changePlan, SkillVersion(1)),
        wording: SkillWording(
            name: "Change the plan", summary: "Suggest a new time, activity, or friend", startAction: "Suggest it",
            acceptAction: "Sounds good", declineAction: "Keep it as is", declineNote: "If you pass, the plan just stays as it was."
        ),
        buildingBlock: .negotiationWithPrivateLimits,
        // Locally only: nothing must leave for the skill to run, so no topic
        // is required (ADR 0019 decision 7); people is used to add a friend.
        topicsUsed: [.time, .activity, .people],
        topicsRequired: [],
        accepts: [.plan],
        produces: [.plan],
        intent: try! IntentSchema(slots: [
            IntentSlot(.time, required: false, hint: "the new time, such as 8:30 instead"),
            IntentSlot(.activity, required: false, hint: "the new activity, such as dinner instead of boba"),
            IntentSlot(.people, required: false, hint: "a friend to add, by name"),
        ], asksForAudience: false, asksForExpiry: false),
        chainTrigger: .whilePlanned,
        sendModes: [.invite]
    )

    /// How long a suggestion stays open: two hours, but never past the plan's
    /// start, and at least ten minutes.
    public static func defaultExpiry(for plan: Plan, now: Date) -> Timestamp {
        var end = now.addingTimeInterval(2 * 3600)
        if let start = plan.time?.start, start > now { end = min(end, start) }
        return Timestamp(max(end, now.addingTimeInterval(600)))
    }
}

/// What a suggestion changes, or leaving.
public enum PlanChange: Hashable, Sendable {
    /// A new time, a new activity, a friend to add, or any of them together.
    case change(time: TimeSlot?, activity: Keyword?, adding: PeerID?)
    /// Leave the plan. Needs no agreement (ADR 0022 decision 5).
    case leave

    public enum Invalid: Error, Hashable, Sendable {
        /// Changes nothing, adds someone already in the plan, or would leave
        /// the plan with neither activity nor time.
        case nothingToChange
        /// The request carries no plan, or a change in a shape this skill does not read.
        case unreadable
    }

    /// The `rules` and `extraInputs` for `ChainPlanner.beginChange` (or
    /// `beginLeave`). Time is a single `within` window, activity a single
    /// liked keyword, a friend to add the plan's roster plus them, and
    /// leaving a `mustBe(false)` on people.
    public func encoded(for plan: Plan) throws -> (rules: OwnerRules, inputs: [Artifact]) {
        switch self {
        case .leave:
            return (OwnerRules(constraints: try ConstraintSet([.people: [try Constraint(.mustBe(false))]])), [])
        case .change(let time, let activity, let adding):
            _ = try applied(to: plan)
            var constraints: [IssueKey: [Constraint]] = [:]
            if let time { constraints[.time] = [try Constraint(.within([time]))] }
            if let activity { constraints[.activity] = [try Constraint(.prefers(liked: [activity], avoided: []))] }
            let inputs: [Artifact] = try adding.map { [.attendees(try Attendees(plan.attendees.peers + [$0]))] } ?? []
            return (OwnerRules(constraints: try ConstraintSet(constraints)), inputs)
        }
    }

    /// The change and the plan it changes, read back from a request.
    public static func decode(_ request: SkillRequest) throws -> (basis: Plan, change: PlanChange) {
        guard let basis = request.inputs.lazy.compactMap({ if case .plan(let plan) = $0 { plan } else { nil } }).first else { throw Invalid.unreadable }
        let constraints = request.intent.rules.constraints
        if constraints[.people].contains(where: { $0.rule == .mustBe(false) }) { return (basis, .leave) }
        var time: TimeSlot?
        if let rule = constraints[.time].first?.rule {
            guard case .within(let slots) = rule, slots.count == 1 else { throw Invalid.unreadable }
            time = slots[0]
        }
        var activity: Keyword?
        if let rule = constraints[.activity].first?.rule {
            guard case .prefers(let liked, _) = rule, liked.count == 1 else { throw Invalid.unreadable }
            activity = liked[0]
        }
        var adding: PeerID?
        if let roster = request.inputs.lazy.compactMap({ if case .attendees(let attendees) = $0 { attendees } else { nil } }).first {
            let added = roster.peers.filter { !basis.attendees.peers.contains($0) }
            guard added.count == 1, roster.peers.count == basis.attendees.peers.count + 1 else { throw Invalid.unreadable }
            adding = added[0]
        }
        let change = PlanChange.change(time: time, activity: activity, adding: adding)
        _ = try change.applied(to: basis)
        return (basis, change)
    }

    /// The plan after this change, with the revision one higher.
    public func applied(to plan: Plan) throws -> Plan {
        guard case .change(let time, let activity, let adding) = self else { throw Invalid.nothingToChange }
        if let adding, plan.attendees.peers.contains(adding) { throw Invalid.nothingToChange }
        let changesTime = time != nil && time != plan.time
        let changesActivity = activity != nil && activity != plan.activity
        guard changesTime || changesActivity || adding != nil else { throw Invalid.nothingToChange }
        let attendees = try adding.map { try Attendees(plan.attendees.peers + [$0]) }
        return try plan.updating(attendees: attendees, activity: activity.map { .some($0) }, time: time.map { .some($0) })
    }

    /// What a suggestion sends to everyone else in the plan: only what
    /// changes. A friend to add travels as the new roster, under people.
    func terms(for plan: Plan) throws -> Terms {
        guard case .change(let time, let activity, let adding) = self else { throw Invalid.nothingToChange }
        var values: [IssueKey: IssueValue] = [:]
        if let time { values[.time] = .slots([time]) }
        if let activity { values[.activity] = .keywords([activity]) }
        if let adding { values[.people] = .peers(plan.attendees.peers + [adding]) }
        return try Terms(values)
    }

    /// A suggestion read from a friend's terms, against this phone's plan;
    /// nil when it is not one this skill accepts.
    static func suggestion(from terms: Terms, basis plan: Plan) -> (change: PlanChange, proposed: Plan)? {
        let values = terms.values
        guard !values.isEmpty, Set(values.keys).isSubset(of: [.time, .activity, .people]) else { return nil }
        var time: TimeSlot?
        if let value = values[.time] {
            guard case .slots(let slots) = value, slots.count == 1 else { return nil }
            time = slots[0]
        }
        var activity: Keyword?
        if let value = values[.activity] {
            guard case .keywords(let keywords) = value, keywords.count == 1 else { return nil }
            activity = keywords[0]
        }
        var adding: PeerID?
        if let value = values[.people] {
            // Nobody is removed: the roster is the plan's plus exactly one.
            guard case .peers(let roster) = value, roster.count == plan.attendees.peers.count + 1,
                  Array(roster.prefix(plan.attendees.peers.count)) == plan.attendees.peers,
                  let added = roster.last, !plan.attendees.peers.contains(added)
            else { return nil }
            adding = added
        }
        let change = PlanChange.change(time: time, activity: activity, adding: adding)
        guard let proposed = try? change.applied(to: plan) else { return nil }
        return (change, proposed)
    }

    /// What a friend being added is shown: the plan as it will be, its people
    /// under the people topic.
    static func inviteTerms(for plan: Plan) throws -> Terms {
        var values: [IssueKey: IssueValue] = [.people: .peers(plan.attendees.peers)]
        if let activity = plan.activity { values[.activity] = .keywords([activity]) }
        if let time = plan.time { values[.time] = .slots([time]) }
        if let place = plan.place { values[.place] = .places([place]) }
        return try Terms(values)
    }

    /// The plan a friend is invited into, read from an invite; nil if the
    /// invite does not include them and the sender, or names neither an
    /// activity nor a time.
    static func invitedPlan(from terms: Terms, origin: ConversationID, revision: UInt32, sender: PeerID, me: PeerID) -> Plan? {
        let values = terms.values
        guard Set(values.keys).isSubset(of: [.time, .activity, .place, .people]),
              case .peers(let roster) = values[.people], roster.contains(me), roster.contains(sender),
              let attendees = try? Attendees(roster)
        else { return nil }
        var activity: Keyword?
        if let value = values[.activity] {
            guard case .keywords(let keywords) = value, keywords.count == 1 else { return nil }
            activity = keywords[0]
        }
        var time: TimeSlot?
        if let value = values[.time] {
            guard case .slots(let slots) = value, slots.count == 1 else { return nil }
            time = slots[0]
        }
        var place: PlaceChoice?
        if let value = values[.place] {
            guard case .places(let places) = value, places.count == 1 else { return nil }
            place = places[0]
        }
        return try? Plan(origin: origin, attendees: attendees, activity: activity, time: time, place: place, revision: revision)
    }
}
