import Foundation
import StarlingCore
import StarlingPolicy
import Testing

@Suite struct ConsentSheetTests {
    @Test(arguments: [ModelLocality.onDevice, .none, .privateCloudCompute, .thirdPartyCloud(provider: "example")])
    func localityIsAlwaysLabeledAsSelfDeclared(locality: ModelLocality) {
        let sheet = ConsentSheetModel(disclosure: Disclosure(recipient: Fixtures.bob.id, recipientModel: locality, items: []))
        #expect(sheet.localityNotice.contains("self-declared"))
        #expect(sheet.localityNotice.contains("not been independently verified"))
        if case .thirdPartyCloud(let provider) = locality { #expect(sheet.recipientModelDescription.contains(provider)) }
        #expect(sheet.recipient == Fixtures.bob.id)
        #expect(sheet.protocolNotice.contains("peer identifiers"))
    }

    @Test func missingCardIsUnknownNotOnDevice() {
        let sheet = ConsentSheetModel(disclosure: Disclosure(recipient: Fixtures.bob.id, recipientModel: nil, items: []))
        #expect(sheet.recipientModelDescription.contains("unknown"))
        #expect(sheet.localityNotice.contains("could use a cloud model"))
    }

    @Test func valueRowsAreClearAndKeepExactTypedValues() throws {
        let cases: [(IssueKey, IssueValue, String)] = [
            (.activity, Fixtures.value, "boba"),
            (.budget, .amount(try MoneyAmount(minorUnits: 1575)), "15.75 USD"),
            (.budget, .amount(try MoneyAmount(minorUnits: 1575, currency: "JPY")), "1575 minor units (JPY)"),
            (.partySize, .count(3), "3"),
            (try IssueKey("interest"), .flag(false), "No"),
            (try IssueKey("interest"), .flag(true), "Yes"),
            (.activity, .keywords([]), "Empty keyword list"),
            (.time, .slots([]), "Empty availability list"),
            (.time, .slots([try TimeSlot(startMinute: 0, endMinute: 30)]),
             "1970-01-01 00:00 UTC to 1970-01-01 00:30 UTC (end excluded)"),
            (.time, .slots([try TimeSlot(startMinute: Int64.max - 1, endMinute: Int64.max)]),
             "UTC minute \(Int64.max - 1) since 1970 to UTC minute \(Int64.max) since 1970 (end excluded)"),
        ]
        for (issue, value, expected) in cases {
            let item = DisclosedItem(category: .terms, issue: issue, value: value)
            let sheet = ConsentSheetModel(disclosure: Disclosure(recipient: Fixtures.bob.id, recipientModel: .onDevice, items: [item]))
            #expect(sheet.rows.count == 1)
            #expect(sheet.rows[0].item == item)
            #expect(sheet.rows[0].detail == expected)
        }
    }

    @Test func nonPrivatePSIShowsFullInputsAndWarning() async throws {
        let engine = Fixtures.engine()
        try await Fixtures.registerContext(engine)
        let sheet = ConsentSheetModel(disclosure: try await engine.disclosure(for: Fixtures.outbound(Fixtures.body(.psi))))
        #expect(sheet.rows[0].detail == "Full input set: boba")
        #expect(sheet.psiNotice?.contains("not private") == true)
    }

    @Test func markerRowsDoNotInventValuesOrPrivacy() {
        let items: [DisclosedItem] = [
            DisclosedItem(category: .agentCard, issue: nil, value: nil),
            DisclosedItem(category: .psi, issue: .activity, value: nil),
        ]
        let sheet = ConsentSheetModel(disclosure: Disclosure(recipient: Fixtures.bob.id, recipientModel: nil, items: items))
        #expect(sheet.rows[0].detail.contains("Supported protocol versions"))
        #expect(sheet.rows[1].detail.contains("no readable input value"))
        #expect(sheet.psiNotice?.contains("does not independently verify") == true)
    }
}
