import CoreLocation
import Foundation
import PickAPlace
import StarlingCore

/// Location When In Use for Pick a place, on Core Location (ADR 0013, 0232).
///
/// Nothing here runs at launch. The app calls `requestWhenInUse()` only from
/// the Continue button of Starling's sheet, the first time the owner asks
/// for nearby places. The app's Info.plist needs
/// `NSLocationWhenInUseUsageDescription` (`PickAPlaceSkill.locationPurpose`);
/// without it, iOS shows no prompt.
@MainActor
public final class CoreLocationAccess: NSObject, LocationAccess {
    public enum Failure: Error, Hashable, Sendable {
        case notAllowed
        case unavailable
    }

    private let manager = CLLocationManager()
    private var authorizationWaiters: [CheckedContinuation<LocationAuthorization, Never>] = []
    private var positionWaiters: [CheckedContinuation<Coordinate, any Error>] = []

    public override init() {
        super.init()
        manager.delegate = self
        // A search area, not navigation: a block or so is plenty.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    public func authorization() async -> LocationAuthorization { Self.map(manager.authorizationStatus) }

    public func requestWhenInUse() async -> LocationAuthorization {
        let current = Self.map(manager.authorizationStatus)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
            if authorizationWaiters.count == 1 { manager.requestWhenInUseAuthorization() }
        }
    }

    /// One position, used as the center of a search on this phone only.
    public func currentCoordinate() async throws -> Coordinate {
        guard Self.map(manager.authorizationStatus) == .whenInUse else { throw Failure.notAllowed }
        return try await withCheckedThrowingContinuation { continuation in
            positionWaiters.append(continuation)
            if positionWaiters.count == 1 { manager.requestLocation() }
        }
    }

    static func map(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        // Pick a place never asks for Always; if the app has it, When In Use
        // is covered.
        case .authorizedWhenInUse, .authorizedAlways: .whenInUse
        @unknown default: .denied
        }
    }

    fileprivate func authorizationChanged() {
        let status = Self.map(manager.authorizationStatus)
        guard status != .notDetermined else { return }
        let waiters = authorizationWaiters
        authorizationWaiters = []
        waiters.forEach { $0.resume(returning: status) }
    }

    fileprivate func finishPosition(_ result: Result<Coordinate, any Error>) {
        let waiters = positionWaiters
        positionWaiters = []
        waiters.forEach { $0.resume(with: result) }
    }
}

extension CoreLocationAccess: @MainActor CLLocationManagerDelegate {
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationChanged()
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let point = locations.last?.coordinate, let coordinate = try? Coordinate(latitude: point.latitude, longitude: point.longitude) else {
            finishPosition(.failure(Failure.unavailable))
            return
        }
        finishPosition(.success(coordinate))
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        finishPosition(.failure(error))
    }
}
