@testable import StarlingWiFiAware
import Testing

@Suite struct WiFiAwareServiceNameTests {
    /// An invalid name in Info.plist crashes the app, so Starling's own names
    /// are checked against Apple's rules here rather than on a device.
    @Test(arguments: StarlingWiFiAwareService.all)
    func starlingServicesAreValid(name: String) {
        #expect(WiFiAwareServiceName.isValid(name))
    }

    @Test func starlingServicesAreDistinct() {
        #expect(Set(StarlingWiFiAwareService.all).count == StarlingWiFiAwareService.all.count)
    }

    @Test(arguments: [
        "_example-service._tcp",
        "_example-service._udp",
        "_a._tcp",
        "_A1._udp",
        "_abcdefghijklmno._tcp",
    ])
    func acceptsNamesApplesRulesAllow(name: String) {
        #expect(WiFiAwareServiceName.isValid(name))
    }

    @Test(arguments: [
        "",
        "starling._tcp",            // no leading underscore
        "_starling",                // no protocol
        "_starling._sctp",          // wrong protocol
        "_starling.tcp",            // protocol without underscore
        "_._tcp",                   // empty name
        "_abcdefghijklmnop._tcp",   // 16 characters
        "_-starling._tcp",          // leading hyphen
        "_starling-._tcp",          // trailing hyphen
        "_1234._tcp",               // no letter
        "_star_ling._tcp",          // underscore inside
        "_star.ling._tcp",          // dot inside
        "_starlïng._tcp",           // non-ASCII letter
        "_star ling._tcp",          // space
    ])
    func rejectsNamesApplesRulesForbid(name: String) {
        #expect(!WiFiAwareServiceName.isValid(name))
    }
}
