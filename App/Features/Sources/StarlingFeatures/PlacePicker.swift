import Foundation
import Observation
import PickAPlace
import StarlingCore

/// Location When In Use behind Starling's sheet (ADR 0013): lane D's
/// `LocationAccess` as a `PermissionAccess`, so the permission gate shows
/// the sheet first and the system alert only after Continue.
public struct LocationPermissionAccess: PermissionAccess {
    public let permission = SystemPermission.locationWhenInUse
    private let location: any LocationAccess

    public init(location: any LocationAccess) {
        self.location = location
    }

    public func status() async -> PermissionStatus {
        Self.map(await location.authorization())
    }

    public func request() async -> PermissionStatus {
        Self.map(await location.requestWhenInUse())
    }

    static func map(_ authorization: LocationAuthorization) -> PermissionStatus {
        switch authorization {
        case .notDetermined: .notDetermined
        case .whenInUse: .granted
        case .denied, .restricted: .denied
        }
    }
}

/// Pick a place's part of New (P15-D request 2): look for places near an
/// area the owner types, or nearby, pick which to ask about, or type them
/// when search cannot help. The candidates are staged under the
/// interaction's ID just before it starts, so they exist before anything is
/// sent, and location is asked only through Starling's sheet (ADR 0232).
@MainActor
@Observable
public final class PlacePicker {
    public enum Status: Hashable, Sendable {
        case idle
        case searching
        case found
        /// Search could not help; the owner can type places.
        case manualEntry(ManualEntryReason)
    }

    /// What to look for, such as "dinner" or "boba".
    public var what = ""
    /// The area to look in, such as "near Franklin"; ignored for Nearby.
    public var area = ""
    public var nearby = false
    public private(set) var status = Status.idle
    public private(set) var results: [PlaceCandidate] = []
    public private(set) var typed: [PlaceCandidate] = []
    public var selected: Set<PlaceChoice> = []
    public private(set) var notice: String?

    private let finder: PlaceFinder
    private let staging: StagedCandidates

    public init(finder: PlaceFinder, staging: StagedCandidates) {
        self.finder = finder
        self.staging = staging
    }

    /// Every candidate the owner chose, found or typed.
    public var chosen: [PlaceCandidate] {
        (results + typed).filter { selected.contains($0.choice) }
    }

    /// The chosen candidates that fit the owner's own limits, which is what
    /// the service asks about (`PickAPlaceSkill.askable`).
    public func askable(limits: ConstraintSet) -> [PlaceChoice] {
        PickAPlaceSkill.askable(chosen, limits: limits)
    }

    /// Searches near the area, or nearby. Nearby the first time shows
    /// Starling's location sheet through `permissions`, then searches; a
    /// denial leaves the owner typing places (ADR 0013).
    public func search(permissions: PermissionGate, skill: SkillDescriptor, friends: [String], settings: SettingsModel) async {
        let words = what.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            notice = "Say what kind of place, like dinner or boba."
            return
        }
        status = .searching
        notice = nil
        let place: PlaceArea = nearby ? .nearby : .named(area.trimmingCharacters(in: .whitespacesAndNewlines))
        var result = await finder.find(words, near: place)
        if result == .needsLocationPermission {
            switch await permissions.prepare(.locationWhenInUse, for: skill, friends: friends, settings: settings) {
            case .granted, .limited: result = await finder.find(words, near: .nearby)
            case .askInstead, .unavailable: result = .manualEntry(.locationDenied)
            }
        }
        show(result)
    }

    private func show(_ result: PlaceSearchResult) {
        switch result {
        case .found(let candidates):
            results = candidates
            // The first few are picked; the owner can change it.
            selected = Set(candidates.prefix(4).map(\.choice)).union(typed.map(\.choice))
            status = .found
        case .needsLocationPermission, .manualEntry(.locationDenied):
            status = .manualEntry(.locationDenied)
            notice = PickAPlaceSkill.locationSheet.deniedNote
        case .manualEntry(let reason):
            status = .manualEntry(reason)
            notice = switch reason {
            case .noResults: "Nothing came up. Try another area, or type a place."
            case .locationUnavailable: "Starling couldn't tell where you are. Type an area or a place."
            case .searchFailed: "Maps couldn't search right now. Type a place instead."
            case .locationDenied: PickAPlaceSkill.locationSheet.deniedNote
            }
        }
    }

    /// A place the owner typed. Returns false for a name Starling cannot
    /// send (empty, too long, or with line breaks).
    @discardableResult
    public func add(_ name: String) -> Bool {
        guard let candidate = try? PlaceCandidate.manual(name), !(results + typed).contains(where: { $0.choice == candidate.choice }) else { return false }
        typed.append(candidate)
        selected.insert(candidate.choice)
        return true
    }

    public func toggle(_ choice: PlaceChoice) {
        if selected.contains(choice) { selected.remove(choice) } else { selected.insert(choice) }
    }

    /// Hands the candidates the owner reviewed to the service for
    /// `interaction`, just before the coordinator starts it.
    func stage(_ candidates: [PlaceCandidate], for interaction: InteractionID) async {
        await staging.stage(candidates, for: interaction)
    }

    public func clear() {
        what = ""
        area = ""
        nearby = false
        status = .idle
        results = []
        typed = []
        selected = []
        notice = nil
    }
}
