import Foundation
import FoundationModels
import StarlingCore

// Schemas for SkillModel (ADR 0016), built per call from the skills that can
// run and from a skill's IntentSchema, so the model can only name a skill
// that exists and only fill the slots that skill has (ADR 0010, decision 2).

/// "Which skill does what the owner asks?" as a runtime enum: the ids of the
/// skills that can run now, then `none`.
package struct RouteSchema {
    package static let none = "none"

    package let skills: [SkillDescriptor]
    package let choices: [String]
    package let schema: GenerationSchema

    package init(skills: [SkillDescriptor]) throws {
        self.skills = skills
        choices = skills.map(\.id.rawValue) + [Self.none]
        let property = DynamicGenerationSchema.Property(
            name: "skill",
            description: "The skill that does what the owner asks, or none",
            schema: DynamicGenerationSchema(name: "Skill", anyOf: choices)
        )
        schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Route", properties: [property]), dependencies: [])
    }

    /// Reads the choice. Anything the schema should have made impossible
    /// throws rather than being trusted.
    package func skill(from content: GeneratedContent) throws -> SkillID? {
        try skill(named: content.value(String.self, forProperty: "skill"))
    }

    package func skill(named choice: String) throws -> SkillID? {
        guard choice != Self.none else { return nil }
        guard let skill = skills.first(where: { $0.id.rawValue == choice }) else {
            throw AgentModelError.invalidOutput("skill \(choice) not offered")
        }
        return skill.id
    }
}

/// The model's raw reading of the owner's words for one skill, before
/// grounding and mapping.
package struct RawIntent: Hashable, Sendable {
    package enum Audience: String, Hashable, Sendable, CaseIterable {
        case none, everyone, closeFriends, named
    }

    package var rules = RawRules()
    /// Keywords for slots other than time, activity, and budget ("nearby").
    package var extras: [IssueKey: [String]] = [:]
    package var audience = Audience.none
    package var names: [String] = []

    package init(rules: RawRules = RawRules(), extras: [IssueKey: [String]] = [:], audience: Audience = .none, names: [String] = []) {
        self.rules = rules
        self.extras = extras
        self.audience = audience
        self.names = names
    }
}

/// The guided-generation schema for one skill's `IntentSchema`: a field for
/// each slot the skill has, in the skill's order, plus who to ask when the
/// skill asks for an audience. ADR 0161's schema lessons carry over: enums
/// lead with `none`, and hours and budget are non-optional with sentinels
/// (0, 24, 0) for "not stated".
package struct IntentGenerationSchema {
    package static let days = ["none", "today", "tonight", "tomorrow", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    package static let parts = ["none", "morning", "lunch", "afternoon", "evening"]
    package static let maxWords = 5
    package static let maxNames = 4

    package let skill: SkillDescriptor
    package let schema: GenerationSchema
    /// Property names in generation order, for tests and debugging.
    package let properties: [String]

    package init(skill: SkillDescriptor) throws {
        self.skill = skill
        var properties: [DynamicGenerationSchema.Property] = []
        var names: [String] = []
        func add(_ name: String, _ description: String, _ schema: DynamicGenerationSchema) {
            names.append(name)
            properties.append(DynamicGenerationSchema.Property(name: name, description: description, schema: schema))
        }
        func words(_ limit: Int) -> DynamicGenerationSchema {
            DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self), minimumElements: 0, maximumElements: limit)
        }
        for slot in skill.intent.slots {
            switch slot.issue {
            case .activity:
                add("wants", "Things the owner asked for: \(slot.hint)", words(Self.maxWords))
                add("avoids", "Things the owner ruled out", words(Self.maxWords))
            case .time:
                add("day", "Day the owner named", DynamicGenerationSchema(name: "Day", anyOf: Self.days))
                add("earliestHour", "Earliest hour the owner named, 0-23, or 0 if none", DynamicGenerationSchema(type: Int.self, guides: [.range(0...23)]))
                add("latestHour", "Latest hour the owner named, 1-24, or 24 if none", DynamicGenerationSchema(type: Int.self, guides: [.range(1...24)]))
                add("partOfDay", "Part of the day the owner named, if no hours", DynamicGenerationSchema(name: "PartOfDay", anyOf: Self.parts))
            case .budget:
                add("maxDollars", "Most the owner will spend in whole dollars, or 0 if none", DynamicGenerationSchema(type: Int.self, guides: [.range(0...DecisionSchema.maxDollars)]))
            default:
                add(Self.extraName(slot.issue), "Words the owner used for \(slot.hint)", words(3))
            }
        }
        if skill.intent.asksForAudience {
            add("audience", "Who the owner wants to ask", DynamicGenerationSchema(name: "Audience", anyOf: RawIntent.Audience.allCases.map(\.rawValue)))
            add("names", "Names of people the owner mentioned, as written", words(Self.maxNames))
        }
        self.properties = names
        schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Intent", properties: properties), dependencies: [])
    }

    /// A colon cannot appear in an IssueKey, so no slot's name collides
    /// with the fixed ones.
    package static func extraName(_ issue: IssueKey) -> String { "issue:\(issue.rawValue)" }

    package func raw(from content: GeneratedContent) throws -> RawIntent {
        func strings(_ name: String) throws -> [String] { try content.value([String].self, forProperty: name) }
        var raw = RawIntent()
        for name in properties {
            switch name {
            case "wants": raw.rules.wants = try strings(name)
            case "avoids": raw.rules.avoids = try strings(name)
            case "day": raw.rules.day = try Self.day(content.value(String.self, forProperty: name))
            case "earliestHour":
                let hour = try content.value(Int.self, forProperty: name)
                raw.rules.earliestHour = hour == 0 ? nil : hour
            case "latestHour":
                let hour = try content.value(Int.self, forProperty: name)
                raw.rules.latestHour = hour == 24 ? nil : hour
            case "partOfDay": raw.rules.partOfDay = try Self.part(content.value(String.self, forProperty: name))
            case "maxDollars":
                let dollars = try content.value(Int.self, forProperty: name)
                raw.rules.maxDollars = dollars == 0 ? nil : dollars
            case "audience":
                let choice = try content.value(String.self, forProperty: name)
                guard let audience = RawIntent.Audience(rawValue: choice) else { throw AgentModelError.invalidOutput("audience \(choice)") }
                raw.audience = audience
            case "names": raw.names = try strings(name)
            default:
                guard name.hasPrefix("issue:"), let issue = try? IssueKey(String(name.dropFirst(6))) else { continue }
                raw.extras[issue] = try strings(name)
            }
        }
        // "tonight" names the evening as well as the day.
        if raw.rules.day == .relative(0), raw.rules.partOfDay == nil, (try? content.value(String.self, forProperty: "day")) == "tonight" {
            raw.rules.partOfDay = .evening
        }
        return raw
    }

    static func day(_ choice: String) throws -> RawRules.Day? {
        switch choice {
        case "none": return nil
        case "today", "tonight": return .relative(0)
        case "tomorrow": return .relative(1)
        default:
            guard let index = days.firstIndex(of: choice), index >= 4 else { throw AgentModelError.invalidOutput("day \(choice)") }
            // monday is index 4 and weekday 2; sunday is index 10 and weekday 1.
            return .weekday(index == 10 ? 1 : index - 2)
        }
    }

    static func part(_ choice: String) throws -> RawRules.PartOfDay? {
        switch choice {
        case "none": nil
        case "morning": .morning
        case "lunch": .lunch
        case "afternoon": .afternoon
        case "evening": .evening
        default: throw AgentModelError.invalidOutput("part of day \(choice)")
        }
    }
}

/// One proposal sentence, with the place left as a placeholder the code
/// fills in: venue names are peer-supplied text and stay out of prompts
/// (ADR 0012).
package enum ProposalSentence {
    package static let placeholder = "{place}"
    package static let timePlaceholder = "{time}"
    package static let maxCharacters = 200

    package static func schema() throws -> GenerationSchema {
        let property = DynamicGenerationSchema.Property(
            name: "sentence", description: "One or two short sentences for the owner",
            schema: DynamicGenerationSchema(type: String.self)
        )
        return try GenerationSchema(root: DynamicGenerationSchema(name: "Proposal", properties: [property]), dependencies: [])
    }
}
