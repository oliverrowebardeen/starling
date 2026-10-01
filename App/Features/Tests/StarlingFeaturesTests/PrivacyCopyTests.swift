import Foundation
import StarlingCore
@testable import StarlingFeatures
import Testing

@Suite struct PrivacyCopyTests {
    /// ADR 0019: every topic but time and activity has the same control,
    /// including location and calendar details, in You's order.
    @Test func everyTopicButTimeAndActivityHasAControl() {
        #expect(PrivacyCopy.topics == [.place, .location, .budget, .diet, .people, .photos, .interests, .calendarDetails])
    }

    /// ADR 0019 decision 8: each choice explains itself, and Never does not
    /// overclaim: friends can learn whether an option works.
    @Test func eachChoiceExplainsItself() {
        #expect(PrivacyCopy.explanation(.share).contains("without asking"))
        #expect(PrivacyCopy.explanation(.askMe).contains("approve"))
        #expect(PrivacyCopy.explanation(.never).hasPrefix("Stays on this phone."))
        #expect(PrivacyCopy.explanation(.never).contains("friends can learn whether an option works"))
        for choice in SharingChoice.allCases {
            #expect(!PrivacyCopy.explanation(choice).contains("\u{2014}"))
        }
    }

    @Test func calendarDetailsAreNotSentBySkillsYet() {
        #expect(!PrivacyCopy.isSentBySomeSkill(.calendarDetails))
        #expect(PrivacyCopy.isSentBySomeSkill(.budget))
    }

    /// ADR 0019 decision 2: the privacy-protective defaults You starts from.
    @Test func youStartsFromTheNewDefaults() {
        let settings = PrivacySettings.defaults
        #expect(settings.choice(for: .budget) == .never)
        #expect(settings.choice(for: .calendarDetails) == .never)
        #expect(settings.choice(for: .interests) == .share)
        #expect(settings.choice(for: .location) == .askMe)
        #expect(PrivacyTopic.location.label == "Exact location")
        #expect(PrivacyTopic.calendarDetails.label == "Calendar details")
    }
}
