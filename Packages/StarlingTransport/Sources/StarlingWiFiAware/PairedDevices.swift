import Foundation
import Observation
#if canImport(WiFiAware) && os(iOS) && !targetEnvironment(macCatalyst)
import WiFiAware
#endif

/// A device paired with this app over Wi-Fi Aware, as the system lists it.
/// This is OS pairing only: the Starling identity behind it is pinned
/// separately by lane E1's pairing ceremony over the resulting link.
public struct WiFiAwarePairedDevice: Hashable, Sendable, Identifiable {
    /// The system's ID for the device, local to this phone.
    public let id: UInt64
    /// The best name the system has for the device.
    public let name: String

    public init(id: UInt64, name: String) {
        self.id = id
        self.name = name
    }

    /// Prefers the device's name, then the name it paired under.
    package init(id: UInt64, name: String?, pairingName: String?) {
        let candidates = [name, pairingName].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        self.init(id: id, name: candidates.first { !$0.isEmpty } ?? "Unnamed device")
    }

    package static func sorted(_ devices: some Sequence<WiFiAwarePairedDevice>) -> [WiFiAwarePairedDevice] {
        devices.sorted { lhs, rhs in
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.id < rhs.id
            }
        }
    }
}

#if canImport(WiFiAware) && os(iOS) && !targetEnvironment(macCatalyst)
extension WiFiAwarePairedDevice {
    init(_ device: WAPairedDevice) {
        self.init(id: device.id, name: device.name, pairingName: device.pairingInfo?.pairingName)
    }
}
#endif

/// The devices paired with this app, kept current for a paired-devices
/// screen. People remove pairings in Settings, not in the app.
@MainActor @Observable
public final class WiFiAwarePairedDevices {
    /// Sorted by name.
    public private(set) var devices: [WiFiAwarePairedDevice]
    /// True when the system list could not be read (for example, Wi-Fi Aware
    /// is unsupported or the entitlement is missing).
    public private(set) var isUnavailable = false

    public init() {
        devices = []
    }

    /// A fixed list, for SwiftUI previews and tests.
    public init(preview devices: [WiFiAwarePairedDevice]) {
        self.devices = WiFiAwarePairedDevice.sorted(devices)
    }

    /// Follows the system's paired-device list until the calling task is
    /// cancelled. Call it from a `.task` modifier. Does nothing where Wi-Fi
    /// Aware does not exist.
    public func track() async {
        #if canImport(WiFiAware) && os(iOS) && !targetEnvironment(macCatalyst)
        let all = WAPairedDevice.allDevices
        do {
            if let current = try await all.current() { show(current.values.map(WiFiAwarePairedDevice.init)) }
        } catch {
            isUnavailable = true
            return
        }
        await track(all.map { $0.values.map(WiFiAwarePairedDevice.init) })
        #endif
    }

    package func track<Updates: AsyncSequence>(_ updates: Updates) async where Updates.Element == [WiFiAwarePairedDevice] {
        do {
            for try await list in updates { show(list) }
        } catch {
            isUnavailable = true
        }
    }

    private func show(_ list: [WiFiAwarePairedDevice]) {
        devices = WiFiAwarePairedDevice.sorted(list)
        isUnavailable = false
    }
}
