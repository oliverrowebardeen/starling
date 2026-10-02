import Foundation
import StarlingCore

/// A first name to prefill when the owner names a new friend, read from
/// the name the friend's phone gave itself ("Riley's iPhone" gives
/// "Riley"). Never the device name itself: a phone's name is not a
/// person's (issue #95). The device name comes from that phone, so the
/// suggestion is only a prefill the owner confirms or edits, and
/// `NicknameCheck` still warns about look-alikes (issue #46, ADR 0260).
public enum FriendNameSuggestion {
    private static let devices = "(?:iphone|ipad|ipod|phone|mac|macbook|watch)"

    /// The patterns, in order: English possessive ("Riley's iPhone 17"),
    /// "iPhone de/von/di/van Riley", and "Riley的iPhone".
    private static let patterns: [(String, Int)] = [
        (#"^\s*(.+?)\s*['’ʼ`]\s*s\s+"# + devices + #"\b.*$"#, 1),
        (#"^\s*(.+?)['’ʼ`]\s+"# + devices + #"\b.*$"#, 1),
        (#"^\s*"# + devices + #"\s+(?:de|von|di|van|da|do)\s+(.+?)\s*$"#, 1),
        (#"^\s*(.+?)\s*的\s*"# + devices + #".*$"#, 1),
    ]

    public static func from(deviceName: String?) -> String? {
        guard let deviceName else { return nil }
        for (pattern, group) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: deviceName, range: NSRange(deviceName.startIndex..., in: deviceName)),
                  let range = Range(match.range(at: group), in: deviceName)
            else { continue }
            let name = deviceName[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.contains(where: \.isLetter),
                  name.range(of: "^" + devices + "$", options: [.regularExpression, .caseInsensitive]) == nil
            else { return nil }
            return String(name.prefix(PairedPeer.maxNicknameCharacters))
        }
        return nil
    }
}
