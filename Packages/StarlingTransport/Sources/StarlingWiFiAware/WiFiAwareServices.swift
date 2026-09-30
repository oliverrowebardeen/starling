import Foundation

/// The Wi-Fi Aware services Starling declares (ADR 0111).
///
/// The app must declare both in `WiFiAwareServices` in its Info.plist, each
/// with `Publishable` and `Subscribable`, and carry the
/// `com.apple.developer.wifi-aware` entitlement with `Publish` and
/// `Subscribe`. The exact snippet is in ADR 0111. A name that is missing from
/// Info.plist makes the transport and pairing views fail; an invalid name in
/// Info.plist crashes the app at launch, which is why `WiFiAwareServiceName`
/// checks these in tests.
public enum StarlingWiFiAwareService {
    /// Carries links between paired friends (`WiFiAwareTransport`).
    public static let link = "_starling-link._tcp"
    /// Used only by the pairing views. Separate from `link` because an app may
    /// publish a given service at most once per device, and the transport's
    /// listener already publishes `link` while the pairing sheet is up.
    public static let pairing = "_starling-pair._tcp"
    /// Every service above, for Info.plist checks.
    public static let all = [link, pairing]
    /// Values of the `com.apple.developer.wifi-aware` entitlement.
    public static let entitlementCapabilities = ["Publish", "Subscribe"]
}

/// Apple's rules for a fully qualified Wi-Fi Aware service name, from
/// "Adopting Wi-Fi Aware" (RFC 6763 section 4.1.2 and RFC 6335 section 5.1):
/// an underscore, a name of 1 to 15 characters using only `a-z`, `A-Z`, `0-9`,
/// and `-`, with at least one letter and no leading or trailing hyphen, then
/// `._tcp` or `._udp`.
package enum WiFiAwareServiceName {
    package static let maxNameCharacters = 15

    package static func isValid(_ fullName: String) -> Bool {
        let scalars = Array(fullName.unicodeScalars)
        guard scalars.first == "_" else { return false }
        let rest = String(String.UnicodeScalarView(scalars.dropFirst()))
        let protocolSuffixes = ["._tcp", "._udp"]
        guard let suffix = protocolSuffixes.first(where: rest.hasSuffix) else { return false }
        let name = Array(rest.dropLast(suffix.count).unicodeScalars)

        guard (1...maxNameCharacters).contains(name.count),
              name.first != "-", name.last != "-",
              name.allSatisfy({ isASCIILetter($0) || ("0"..."9").contains($0) || $0 == "-" }),
              name.contains(where: isASCIILetter)
        else { return false }
        return true
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }
}
