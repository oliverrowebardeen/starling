import Foundation
import StarlingCore
import Testing

@Suite struct PrivacyTopicsTests {
    @Test func everyIssueBelongsToExactlyOneTopic() throws {
        var seen: [IssueKey: PrivacyTopic] = [:]
        for topic in PrivacyTopic.allCases {
            for issue in topic.issues {
                #expect(seen[issue] == nil, "\(issue) is in \(seen[issue]!) and \(topic)")
                seen[issue] = topic
                #expect(PrivacyTopic(issue: issue) == topic)
            }
        }
        #expect(PrivacyTopic(issue: try IssueKey("unheard_of")) == nil)
    }

    @Test func timeAndActivityCannotBeNever() throws {
        #expect(!PrivacyTopic.time.allowsNever && !PrivacyTopic.activity.allowsNever)
        #expect(throws: ValidationError.self) { try PrivacySettings([.time: .never]) }
        var settings = PrivacySettings.defaults
        #expect(throws: ValidationError.self) { try settings.set(.never, for: .activity) }
        try settings.set(.never, for: .place)
        #expect(settings.neverTopics == [.place, .budget, .calendarDetails])
    }

    /// The owner's defaults, 2026-10-01 (ADR 0019).
    @Test func defaultsProtectPrivacy() {
        let expected: [PrivacyTopic: SharingChoice] = [
            .time: .share, .activity: .share, .place: .askMe, .location: .askMe, .budget: .never,
            .diet: .askMe, .people: .askMe, .photos: .askMe, .interests: .share, .calendarDetails: .never,
        ]
        #expect(Set(expected.keys) == Set(PrivacyTopic.allCases))
        for (topic, choice) in expected {
            #expect(PrivacySettings.defaults.choice(for: topic) == choice, "\(topic)")
        }
        // A stored choice wins over the default.
        let chosen = try? PrivacySettings([.budget: .share])
        #expect(chosen?.choice(for: .budget) == .share)
    }

    @Test func locationIsItsOwnTopicApartFromPlace() {
        #expect(PrivacyTopic(issue: .location) == .location)
        #expect(PrivacyTopic(issue: .place) == .place)
        #expect(PrivacyTopic(issue: .calendarDetails) == .calendarDetails)
        #expect(PrivacyTopic.allCases.last == .calendarDetails)
    }

    @Test func choicesExpandToOneRulePerIssue() throws {
        let settings = try PrivacySettings([.budget: .never, .place: .share])
        let rules = Dictionary(uniqueKeysWithValues: settings.disclosureRules.map { ($0.issue, $0.action) })
        #expect(rules.count == PrivacyTopic.allCases.reduce(0) { $0 + $1.issues.count })
        #expect(rules[.budget] == .never)
        #expect(rules[.place] == .allowOnDevicePeers)
        #expect(rules[.diet] == .askEachTime)
        #expect(rules[.calendarDetails] == .never)
        #expect(rules[.interests] == .allowOnDevicePeers)
        #expect(rules[.downLevel] == .allowOnDevicePeers)
        #expect(rules[.partySize] == .askEachTime)
    }

    @Test func decodingRejectsNeverForTheOverlapTopics() throws {
        let bad = Data(#"{"choices":{"time":"never"}}"#.utf8)
        #expect(throws: ValidationError.self) { try JSONDecoder().decode(PrivacySettings.self, from: bad) }
        let good = try PrivacySettings([.photos: .never, .time: .askMe])
        let round = try JSONDecoder().decode(PrivacySettings.self, from: JSONEncoder().encode(good))
        #expect(round == good)
    }
}
