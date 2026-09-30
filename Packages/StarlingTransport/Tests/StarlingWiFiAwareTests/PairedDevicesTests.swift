@testable import StarlingWiFiAware
import Testing

@Suite struct WiFiAwarePairedDeviceTests {
    @Test func prefersTheDeviceNameThenThePairingName() {
        #expect(WiFiAwarePairedDevice(id: 1, name: "Maya's iPhone", pairingName: "iPhone").name == "Maya's iPhone")
        #expect(WiFiAwarePairedDevice(id: 1, name: nil, pairingName: "iPhone").name == "iPhone")
        #expect(WiFiAwarePairedDevice(id: 1, name: "  ", pairingName: " iPhone ").name == "iPhone")
        #expect(WiFiAwarePairedDevice(id: 1, name: nil, pairingName: nil).name == "Unnamed device")
    }

    @Test func sortsByNameThenID() {
        let devices = [
            WiFiAwarePairedDevice(id: 3, name: "iPhone"),
            WiFiAwarePairedDevice(id: 2, name: "Alex"),
            WiFiAwarePairedDevice(id: 1, name: "iPhone"),
            WiFiAwarePairedDevice(id: 4, name: "iPhone 2"),
        ]
        #expect(WiFiAwarePairedDevice.sorted(devices).map(\.id) == [2, 1, 3, 4])
    }
}

@MainActor @Suite struct WiFiAwarePairedDevicesTests {
    private struct Unreadable: Error {}

    @Test func followsUpdatesSorted() async {
        let model = WiFiAwarePairedDevices()
        let (updates, continuation) = AsyncStream.makeStream(of: [WiFiAwarePairedDevice].self)
        continuation.yield([WiFiAwarePairedDevice(id: 1, name: "Sam")])
        continuation.yield([WiFiAwarePairedDevice(id: 1, name: "Sam"), WiFiAwarePairedDevice(id: 2, name: "Alex")])
        continuation.finish()

        await model.track(updates)
        #expect(model.devices.map(\.name) == ["Alex", "Sam"])
        #expect(!model.isUnavailable)
    }

    @Test func marksTheListUnavailableWhenTheSystemFails() async {
        let model = WiFiAwarePairedDevices(preview: [WiFiAwarePairedDevice(id: 1, name: "Sam")])
        let (updates, continuation) = AsyncThrowingStream.makeStream(of: [WiFiAwarePairedDevice].self)
        continuation.finish(throwing: Unreadable())

        await model.track(updates)
        #expect(model.isUnavailable)
        #expect(model.devices.map(\.name) == ["Sam"])
    }

    /// On macOS there is no Wi-Fi Aware, so tracking the system list must
    /// return at once and leave the list alone.
    @Test func systemTrackingIsANoOpWithoutWiFiAware() async {
        let model = WiFiAwarePairedDevices(preview: [WiFiAwarePairedDevice(id: 9, name: "Preview")])
        await model.track()
        #expect(model.devices.map(\.id) == [9])
        #expect(!WiFiAwareSupport.isSupported)
    }
}
