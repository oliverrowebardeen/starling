import Foundation
import StarlingCore

/// Plain presentation data for lane H. Values stay typed for localization or
/// richer UI; display strings never become prompts or outbound message data.
public struct ConsentRow: Hashable, Sendable {
    public let item: DisclosedItem
    public let title: String
    public let detail: String
}

public struct ConsentSheetModel: Hashable, Sendable {
    public let recipient: PeerID
    public let title: String
    public let recipientModelDescription: String
    public let localityNotice: String
    public let rows: [ConsentRow]
    public let protocolNotice: String
    public let psiNotice: String?

    public init(disclosure: Disclosure) {
        recipient = disclosure.recipient
        title = "Share with this peer?"
        switch disclosure.recipientModel {
        case .some(.onDevice): recipientModelDescription = "Recipient declares an on-device model."
        case .some(.none): recipientModelDescription = "Recipient declares no language model."
        case .some(.privateCloudCompute): recipientModelDescription = "Recipient declares Apple Private Cloud Compute."
        case .some(.thirdPartyCloud(let provider)):
            recipientModelDescription = "Recipient declares a cloud model from \(provider)."
        case nil: recipientModelDescription = "The recipient's model location is unknown."
        }
        localityNotice = disclosure.recipientModel == nil
            ? "No agent card has been received. The recipient could use a cloud model."
            : "Model location is self-declared by the recipient and has not been independently verified."
        rows = disclosure.items.map { item in
            ConsentRow(item: item, title: Self.title(for: item), detail: Self.detail(for: item))
        }
        protocolNotice = "Each message also sends peer identifiers, message and conversation identifiers, a sequence number, a timestamp, and protocol metadata."
        if disclosure.items.contains(where: { $0.category == .psi && $0.value != nil }) {
            psiNotice = "This set-matching provider is not private. The recipient may learn the full input set shown here."
        } else if disclosure.items.contains(where: { $0.category == .psi }) {
            psiNotice = "Set matching sends protocol data. This sheet does not independently verify the provider's privacy."
        } else {
            psiNotice = nil
        }
    }

    private static func title(for item: DisclosedItem) -> String {
        if let issue = item.issue {
            switch issue {
            case .time: return "Availability"
            case .activity: return "Activity"
            case .budget: return "Budget"
            case .place: return "Place"
            case .diet: return "Diet"
            case .partySize: return "Group size"
            case .downLevel: return "Your interest"
            default: return issue.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
        switch item.category {
        case .agentCard: return "Agent card"
        case .psi: return "Set matching"
        case .availability: return "Availability"
        case .interest: return "Interest"
        case .terms: return "Plan details"
        }
    }

    private static func detail(for item: DisclosedItem) -> String {
        if let value = item.value {
            if item.issue == .downLevel, case .keywords(let keywords) = value,
               keywords.count == 1, ["down", "maybe"].contains(keywords[0].value) {
                let text = "You said \"\(keywords[0].value)\"."
                return item.category == .psi ? "Full input set: \(text)" : text
            }
            let text = describe(value)
            return item.category == .psi ? "Full input set: \(text)" : text
        }
        switch item.category {
        case .agentCard:
            return "Supported protocol versions, model location, locality evidence, and supported features."
        case .psi:
            return "Set-matching protocol data; no readable input value is included in this row."
        default:
            return "No value is included in this row."
        }
    }

    private static func describe(_ value: IssueValue) -> String {
        switch value {
        case .keywords(let keywords):
            return keywords.isEmpty ? "Empty keyword list" : keywords.map(\.value).joined(separator: ", ")
        case .slots(let slots):
            if slots.isEmpty { return "Empty availability list" }
            return slots.map { "\(minute($0.startMinute)) to \(minute($0.endMinute)) (end excluded)" }.joined(separator: "\n")
        case .amount(let amount):
            // USD minor units are cents. Unknown currency codes retain the exact
            // Core representation instead of guessing their decimal scale.
            if amount.currency == "USD" {
                let cents = String(format: "%02lld", amount.minorUnits % 100)
                return "\(amount.minorUnits / 100).\(cents) USD"
            }
            return "\(amount.minorUnits) minor units (\(amount.currency))"
        case .flag(let flag): return flag ? "Yes" : "No"
        case .count(let count): return String(count)
        }
    }

    private static func minute(_ minute: Int64) -> String {
        // Core accepts minutes beyond calendar formatter ranges. Preserve those
        // exactly rather than showing a rounded or empty date.
        guard minute < 4_223_371_680 else { return "UTC minute \(minute) since 1970" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: Date(timeIntervalSince1970: Double(minute) * 60))
    }
}
