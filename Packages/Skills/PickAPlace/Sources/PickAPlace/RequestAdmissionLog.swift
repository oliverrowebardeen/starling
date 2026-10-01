import Foundation
import StarlingCore

/// When each friend's requests were admitted on this phone, kept across
/// launches, so the hourly limit per friend does not reset when the app
/// restarts (ADR 0230). Stored on the device only.
public protocol RequestAdmissionLog: Sendable {
    /// Admission times since `date`, per friend.
    func admissions(since date: Date) async -> [PeerID: [Date]]
    func record(_ peer: PeerID, at date: Date) async
}

/// For tests and previews. Lives as long as the object, so one shared
/// instance survives a restarted service.
public actor InMemoryRequestAdmissionLog: RequestAdmissionLog {
    private var times: [PeerID: [Date]] = [:]

    public init() {}

    public func admissions(since date: Date) async -> [PeerID: [Date]] {
        times.mapValues { $0.filter { $0 > date } }.filter { !$0.value.isEmpty }
    }

    public func record(_ peer: PeerID, at date: Date) async {
        times[peer, default: []].append(date)
    }
}

/// The app's log, in `UserDefaults`. Keeps the last hour only.
public actor UserDefaultsRequestAdmissionLog: RequestAdmissionLog {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter suiteName: nil for the standard defaults.
    public init(suiteName: String? = nil, key: String = "starling.pick_a_place.admissions") {
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.key = key
    }

    public func admissions(since date: Date) async -> [PeerID: [Date]] {
        var result: [PeerID: [Date]] = [:]
        for (hex, stamps) in stored() {
            guard let peer = try? PeerID(hex: hex) else { continue }
            let recent = stamps.map(Date.init(timeIntervalSince1970:)).filter { $0 > date }
            if !recent.isEmpty { result[peer] = recent }
        }
        return result
    }

    public func record(_ peer: PeerID, at date: Date) async {
        let hourAgo = date.addingTimeInterval(-3_600).timeIntervalSince1970
        var all = stored().mapValues { $0.filter { $0 > hourAgo } }.filter { !$0.value.isEmpty }
        all[peer.hex, default: []].append(date.timeIntervalSince1970)
        defaults.set(all, forKey: key)
    }

    private func stored() -> [String: [Double]] {
        defaults.dictionary(forKey: key) as? [String: [Double]] ?? [:]
    }
}
