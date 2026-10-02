import Foundation
import Observation
import StarlingCore

/// A nearby phone the owner can pair with: reachable on a link, not pinned.
public struct PairingCandidate: Identifiable, Hashable, Sendable {
    public var id: PeerID { peer }
    public let peer: PeerID
    /// The system's name for the phone, where a Wi-Fi Aware link named it.
    /// It labels a phone, never a person (ADR 0260).
    public let deviceName: String?

    public init(peer: PeerID, deviceName: String? = nil) {
        self.peer = peer
        self.deviceName = deviceName
    }

    /// How the sheet names this phone.
    public var label: String { deviceName ?? "Phone \(peer.short)" }
}

/// What the pairing sheet needs from the app's links (lane E1's
/// PairingService and SecureTransports, ADR 0260).
public struct PairingDirectory: Sendable {
    /// This phone's PeerID, so both owners can tell the phones apart.
    public var localPeer: PeerID
    /// Nearby phones that are not paired yet.
    public var candidates: @Sendable () async -> [PairingCandidate]
    /// Phones asking to pair with this one right now.
    public var requests: @Sendable () async -> [PeerID]
    /// Starts a ceremony with a phone, saving it under `nickname` if both
    /// owners confirm. Lane E1 commits the pin; the app never writes it.
    public var pair: @Sendable (PeerID, String) async throws -> any PairingSession
    /// Called once paired, to reconnect each link to the new friend.
    public var paired: @Sendable (PairedPeer) async -> Void
    /// Renames a friend through the pin authority (ADR 0100).
    public var rename: @Sendable (PeerID, String) async throws -> Void
    /// The system's name for the phone behind a peer, where known.
    public var deviceName: @Sendable (PeerID) async -> String?
    /// The pairing sheet opened (Wi-Fi Aware publishes to a phone that
    /// pairs from its picker meanwhile, ADR 0260).
    public var opened: @Sendable () async -> Void
    /// The PeerID behind a device the owner picked in the system's Wi-Fi
    /// Aware picker, or nil if its link hello did not arrive in time. Nil
    /// where Wi-Fi Aware is absent.
    public var peerForPickedDevice: (@Sendable (UInt64) async -> PeerID?)?

    public init(
        localPeer: PeerID,
        candidates: @escaping @Sendable () async -> [PairingCandidate],
        requests: @escaping @Sendable () async -> [PeerID] = { [] },
        pair: @escaping @Sendable (PeerID, String) async throws -> any PairingSession,
        paired: @escaping @Sendable (PairedPeer) async -> Void,
        rename: @escaping @Sendable (PeerID, String) async throws -> Void = { _, _ in },
        deviceName: @escaping @Sendable (PeerID) async -> String? = { _ in nil },
        opened: @escaping @Sendable () async -> Void = {},
        peerForPickedDevice: (@Sendable (UInt64) async -> PeerID?)? = nil
    ) {
        self.localPeer = localPeer
        self.candidates = candidates
        self.requests = requests
        self.pair = pair
        self.paired = paired
        self.rename = rename
        self.deviceName = deviceName
        self.opened = opened
        self.peerForPickedDevice = peerForPickedDevice
    }
}

/// After the first pairing, the one-button explanation before iOS's
/// notification alert (ADR 0013 decision 3, ADR 0260).
public struct NotificationOffer: Sendable {
    /// Whether to show it: iOS has not asked yet.
    public var shouldOffer: @MainActor @Sendable () async -> Bool
    /// Shows the system alert.
    public var ask: @MainActor @Sendable () async -> Void

    public init(shouldOffer: @escaping @MainActor @Sendable () async -> Bool, ask: @escaping @MainActor @Sendable () async -> Void) {
        self.shouldOffer = shouldOffer
        self.ask = ask
    }
}

/// Drives "Add a friend" (ADR 0003, ADR 0101, ADR 0260): one owner picks
/// the other phone, the other phone joins on its own, both compare a code,
/// and then the owner names the friend. Lane E1 saves the friend only if
/// both owners confirm.
@MainActor
@Observable
public final class PairingModel {
    public enum Phase: Hashable, Sendable {
        /// Finding the other phone.
        case choosing
        /// A phone is chosen; waiting for the code.
        case connecting
        /// Both phones show this code. Pairing continues only if both match.
        case comparing(code: String)
        /// This owner confirmed; waiting for the other phone.
        case waiting
        /// Paired under a placeholder name; the owner names the friend.
        case naming(PairedPeer)
        /// The one-button explanation before iOS's notification alert.
        case notifications(friend: String)
        case done
        case failed(PairingFailure)
    }

    /// The name a friend has until the owner names them, never a device name.
    public static let placeholderName = "New friend"

    public private(set) var phase = Phase.choosing
    public private(set) var candidates: [PairingCandidate] = []
    /// The phone in the ceremony, for the sheet's wording.
    public private(set) var phone: PairingCandidate?
    /// The device picked in the system picker, while its link comes up.
    public private(set) var pickedName: String?
    /// The friend's name, prefilled when the code is confirmed.
    public var name = ""
    public private(set) var notice: String?
    public var localPeer: PeerID { directory.localPeer }

    private let directory: PairingDirectory
    private let friends: @MainActor () -> [PairedPeer]
    private let notifications: NotificationOffer?
    private var session: (any PairingSession)?
    private var events: Task<Void, Never>?
    /// Set when the sheet went away, so a session still being created is
    /// cancelled as soon as it exists.
    private var isEnded = false
    /// This owner ended the last ceremony (Cancel, or "They're different"),
    /// so the sheet does not rejoin that phone on its own.
    private var endedHere = false

    /// - Parameters:
    ///   - friends: Every paired friend now, for the nickname check.
    ///   - notifications: Offered after a pairing while iOS has not asked.
    public init(
        directory: PairingDirectory,
        friends: @escaping @MainActor () -> [PairedPeer] = { [] },
        notifications: NotificationOffer? = nil
    ) {
        self.directory = directory
        self.friends = friends
        self.notifications = notifications
    }

    // MARK: Choosing

    /// The sheet appeared.
    public func opened() async {
        await directory.opened()
    }

    /// Refreshes the nearby list and joins a phone that asks to pair. A
    /// request only comes from a phone whose owner picked this one, and the
    /// code comparison still verifies it, so joining saves the second owner
    /// a pick (ADR 0260).
    ///
    /// After a failure, a new request from the same phone is joined too:
    /// its owner tapped Try again, and this owner should not have to.
    public func refresh() async {
        if case .failed = phase, !endedHere, let phone, await directory.requests().contains(phone.peer), case .failed = phase {
            events?.cancel()
            events = nil
            session = nil
            await start(with: phone)
            return
        }
        guard phase == .choosing else { return }
        let fresh = await directory.candidates()
        guard phase == .choosing else { return }
        candidates = fresh
        guard pickedName == nil, let asking = await directory.requests().first, phase == .choosing else { return }
        var deviceName = candidates.first { $0.peer == asking }?.deviceName
        if deviceName == nil { deviceName = await directory.deviceName(asking) }
        guard phase == .choosing else { return }
        await start(with: PairingCandidate(peer: asking, deviceName: deviceName))
    }

    /// The owner tapped a phone in the nearby list.
    public func choose(_ candidate: PairingCandidate) async {
        guard phase == .choosing else { return }
        await start(with: candidate)
    }

    /// The owner picked a device in the system's Wi-Fi Aware picker: pair
    /// with the PeerID behind it once its link says hello.
    public func pickedDevice(id: UInt64, name: String) async {
        guard phase == .choosing, let resolve = directory.peerForPickedDevice else { return }
        let offered = name.trimmingCharacters(in: .whitespacesAndNewlines)
        pickedName = offered.isEmpty ? "the phone you picked" : offered
        notice = nil
        phase = .connecting
        let peer = await resolve(id)
        let label = pickedName
        pickedName = nil
        guard phase == .connecting, !isEnded else { return }
        guard let peer else {
            phase = .choosing
            notice = "Starling couldn't reach \(label ?? "that phone") yet. Keep Starling open on both phones and try again, or pick it below."
            return
        }
        await start(with: PairingCandidate(peer: peer, deviceName: offered.isEmpty ? nil : offered))
    }

    // MARK: The ceremony

    private func start(with candidate: PairingCandidate) async {
        phone = candidate
        endedHere = false
        phase = .connecting
        notice = nil
        do {
            let session = try await directory.pair(candidate.peer, Self.placeholderName)
            if isEnded {
                await session.cancel()
                phase = .failed(.cancelled)
                return
            }
            self.session = session
            events = Task { [weak self] in
                for await event in session.events {
                    await self?.handle(event)
                }
                self?.streamEnded()
            }
        } catch {
            phase = .failed(.transportFailed)
        }
    }

    /// The owner compared the codes on both phones.
    public func confirm(codesMatch: Bool) async {
        guard case .comparing = phase, let session else { return }
        endedHere = !codesMatch
        phase = .waiting
        await session.confirm(codesMatch: codesMatch)
    }

    public func cancel() async {
        endedHere = true
        guard let session else {
            pickedName = nil
            phase = .choosing
            return
        }
        await session.cancel()
    }

    /// Starts again with the same phone, or goes back to choosing one.
    public func tryAgain() async {
        events?.cancel()
        events = nil
        session = nil
        notice = nil
        isEnded = false
        if let phone {
            await start(with: phone)
        } else {
            phase = .choosing
        }
    }

    /// The sheet went away, for example swiped down. Cancels a ceremony in
    /// progress so it does not keep running with no screen; a finished
    /// pairing is left alone.
    public func end() async {
        isEnded = true
        switch phase {
        case .connecting, .comparing, .waiting:
            await session?.cancel()
        case .choosing, .naming, .notifications, .done, .failed:
            break
        }
    }

    func handle(_ event: PairingEvent) async {
        switch event {
        case .confirmCode(let code):
            phase = .comparing(code: code)
        case .paired(let peer):
            await directory.paired(peer)
            var deviceName = phone?.deviceName
            if deviceName == nil { deviceName = await directory.deviceName(peer.id) }
            name = FriendNameSuggestion.from(deviceName: deviceName) ?? ""
            phase = .naming(peer)
        case .failed(let failure):
            phase = .failed(failure)
        }
    }

    private func streamEnded() {
        session = nil
        events = nil
        switch phase {
        case .connecting, .comparing, .waiting:
            // The session ended without a result.
            phase = .failed(.protocolError)
        default:
            break
        }
    }

    // MARK: Naming

    /// A warning when the name matches or looks like another friend's.
    public var nameWarning: String? {
        guard case .naming(let peer) = phase else { return nil }
        return NicknameCheck.warning(for: name, among: friends(), excluding: peer.id)
    }

    public var canSaveName: Bool {
        (1...PairedPeer.maxNicknameCharacters).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count)
    }

    /// Saves the friend's name, then offers notifications if iOS has not asked.
    public func saveName() async {
        guard case .naming(let peer) = phase else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSaveName else {
            notice = "Give them a name of 1 to \(PairedPeer.maxNicknameCharacters) characters."
            return
        }
        if trimmed != peer.nickname {
            do {
                try await directory.rename(peer.id, trimmed)
            } catch {
                notice = "Starling couldn't save that name. Try again, or rename them later in Friends."
                return
            }
        }
        notice = nil
        if let notifications, await notifications.shouldOffer() {
            phase = .notifications(friend: trimmed)
        } else {
            phase = .done
        }
    }

    /// The explanation's one button: straight to the system alert.
    public func continueToNotifications() async {
        guard case .notifications = phase else { return }
        await notifications?.ask()
        phase = .done
    }

    /// What to tell the owner about a failure.
    public static func message(for failure: PairingFailure) -> String {
        switch failure {
        case .codeMismatch:
            "The codes didn't match, so Starling didn't pair. If you picked the right phone, someone nearby may be interfering. Try again somewhere else."
        case .cancelled:
            "Pairing stopped on one of the phones."
        case .timedOut:
            "Pairing took too long. Keep Starling open on both phones and try again."
        case .transportFailed:
            "Starling couldn't reach the other phone. Keep both phones close and try again."
        case .protocolError:
            "The other phone answered in a way Starling didn't expect. Make sure both phones have the latest Starling and try again."
        }
    }
}

/// The names lane P15-F's red-team test still uses (`docs/requests/P15-G.md`
/// request 4), mapped onto the flow of ADR 0260 until that test moves to
/// `phone` and `name`. Not deprecated, because a warning would fail the
/// warnings-as-errors build of a lane this one cannot edit.
extension PairingModel {
    /// The phone being paired.
    public var selected: PairingCandidate? { phone }
    /// The friend's name field. Empty until the codes are confirmed: a
    /// device name never fills it before the owner reviews it.
    public var nickname: String {
        get { name }
        set { name = newValue }
    }
    /// The name the other phone gave itself. It labels the phone; the name
    /// step offers only a first name read from it.
    public var suggestedName: String? { phone?.deviceName }
}
