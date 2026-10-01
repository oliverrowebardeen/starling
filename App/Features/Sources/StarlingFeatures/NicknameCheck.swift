import Foundation
import StarlingCore

/// Nickname hygiene (issue #46). Two friends with one name, or names that
/// only look different ("Alex" with a Cyrillic А), make rosters and consent
/// sheets harder to read. Starling warns and lets the owner choose; pair
/// symbols and `RosterLabels` still tell the friends apart if they keep it.
public enum NicknameCheck {
    /// A warning for `name` against every other friend's nickname, or nil.
    public static func warning(for name: String, among friends: [PairedPeer], excluding peer: PeerID? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let others = friends.filter { $0.id != peer }
        if let same = others.first(where: { $0.nickname.lowercased() == trimmed.lowercased() }) {
            return "You already call another friend \(same.nickname). Pick a different name so you can tell them apart."
        }
        let mine = skeleton(trimmed)
        if let alike = others.first(where: { skeleton($0.nickname) == mine }) {
            return "This looks like \(alike.nickname), another friend's name. Pick a name that's easy to tell apart."
        }
        return nil
    }

    /// A rough version of Unicode's confusable skeleton (UTS #39): fold
    /// compatibility forms, case, and accents, map common look-alike
    /// letters to Latin, and drop invisible characters, spaces, and
    /// punctuation. Two names with the same skeleton read alike.
    public static func skeleton(_ name: String) -> String {
        // Capital I reads like l before case folding loses it.
        let folded = name.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "I", with: "l")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var result = ""
        for scalar in folded.unicodeScalars {
            if let latin = lookalikes[scalar] {
                result.append(latin)
            } else if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
        return result.replacingOccurrences(of: "rn", with: "m")
    }

    private static let lookalikes: [Unicode.Scalar: String] = [
        // Cyrillic
        "а": "a", "в": "b", "е": "e", "ё": "e", "к": "k", "м": "m", "н": "h", "о": "o", "р": "p", "с": "c",
        "т": "t", "у": "y", "х": "x", "і": "l", "ї": "l", "ј": "j", "ѕ": "s", "ԁ": "d", "һ": "h", "ӏ": "l",
        // Greek
        "α": "a", "β": "b", "ε": "e", "η": "n", "ι": "l", "κ": "k", "ν": "v", "ο": "o", "ρ": "p", "τ": "t", "υ": "u", "χ": "x",
        // Latin look-alikes and digits
        "ı": "l", "i": "l", "ɡ": "g", "0": "o", "1": "l", "5": "s", "|": "l",
    ]
}
