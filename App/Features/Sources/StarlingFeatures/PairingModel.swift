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

/// One code on screen, as the buttons that answer it were rendered: the
/// attempt and session that produced it, and the code itself. A confirm
/// carries the token its buttons captured, so it can only answer that
/// comparison (Codex re-review of #104).
public struct PairingComparison: Hashable, Sendable {
    public let code: String
    let attempt: Int
    let session: Int
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
    /// Bumped by every new attempt, by Cancel, and when the sheet goes away.
    /// A session, event, or stream ending from an older attempt is ignored.
    private var attempt = 0
    /// Numbers each installed session, so a comparison names its session.
    private var sessionSerial = 0
    /// The comparison on screen. Buttons capture it when they are rendered.
    public private(set) var comparison: PairingComparison?
    /// The session that produced `comparison`, the only one Confirm answers.
    private var comparedSession: (any PairingSession)?

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
        attempt += 1
        let mine = attempt
        let offered = name.trimmingCharacters(in: .whitespacesAndNewlines)
        pickedName = offered.isEmpty ? "the phone you picked" : offered
        notice = nil
        phase = .connecting
        let peer = await resolve(id)
        // Cancel, or another attempt, while the link came up.
        guard mine == attempt, phase == .connecting, !isEnded else { return }
        let label = pickedName
        pickedName = nil
        guard let peer else {
            phase = .choosing
            notice = "Starling couldn't reach \(label ?? "that phone") yet. Keep Starling open on both phones and try again, or pick it below."
            return
        }
        await start(with: PairingCandidate(peer: peer, deviceName: offered.isEmpty ? nil : offered))
    }

    // MARK: The ceremony

    /// Ends the current attempt on this screen: its session, events, and
    /// shown code. Any call still creating a session for it will find its
    /// attempt obsolete and cancel that session instead of installing it.
    /// Returns the session to cancel, if one was installed.
    private func abandonAttempt() -> (any PairingSession)? {
        attempt += 1
        events?.cancel()
        events = nil
        clearComparison()
        defer { session = nil }
        return session
    }

    private func start(with candidate: PairingCandidate) async {
        // The generation and the starting phase are taken before any await,
        // so a Cancel or another attempt during the old session's cancel
        // makes this one obsolete instead of handing it their generation
        // (Codex re-review of #104).
        let previous = abandonAttempt()
        let mine = attempt
        phone = candidate
        endedHere = false
        phase = .connecting
        notice = nil
        if let previous {
            await previous.cancel()
            guard mine == attempt, !isEnded else { return }
        }
        do {
            let session = try await directory.pair(candidate.peer, Self.placeholderName)
            // Cancel, the sheet closing, or a newer attempt while the
            // session was being created: it is never installed (Codex
            // review of PR #104).
            guard mine == attempt, !isEnded else {
                await session.cancel()
                if mine == attempt { phase = .failed(.cancelled) }
                return
            }
            self.session = session
            sessionSerial += 1
            let serial = sessionSerial
            events = Task { [weak self] in
                for await event in session.events {
                    await self?.handle(event, from: session, serial: serial, attempt: mine)
                }
                self?.streamEnded(attempt: mine)
            }
        } catch {
            if mine == attempt { phase = .failed(.transportFailed) }
        }
    }

    /// The owner compared the codes on both phones. `rendered` is the
    /// comparison the tapped button was drawn for; the answer goes to its
    /// session only if that comparison is still the one on screen, in the
    /// current attempt. Otherwise nothing happens.
    public func confirm(codesMatch: Bool, for rendered: PairingComparison) async {
        guard case .comparing(let code) = phase, let comparison, rendered == comparison,
              rendered.code == code, rendered.attempt == attempt, let session = comparedSession
        else { return }
        clearComparison()
        endedHere = !codesMatch
        phase = .waiting
        await session.confirm(codesMatch: codesMatch)
    }

    private func clearComparison() {
        comparison = nil
        comparedSession = nil
    }

    public func cancel() async {
        endedHere = true
        pickedName = nil
        if let current = abandonAttempt() {
            phase = .failed(.cancelled)
            await current.cancel()
        } else {
            phase = .choosing
        }
    }

    /// Starts again with the same phone, or goes back to choosing one.
    public func tryAgain() async {
        // Only from a failure; a retry already running has left it.
        guard case .failed = phase else { return }
        notice = nil
        isEnded = false
        if let phone {
            await start(with: phone)
        } else {
            _ = abandonAttempt()
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
            let current = abandonAttempt()
            phase = .failed(.cancelled)
            await current?.cancel()
        case .choosing, .naming, .notifications, .done, .failed:
            break
        }
    }

    /// Events from an obsolete attempt are dropped, so a cancelled session
    /// can never put its code on screen.
    func handle(_ event: PairingEvent, from session: any PairingSession, serial: Int, attempt mine: Int) async {
        guard mine == attempt else { return }
        switch event {
        case .confirmCode(let code):
            comparison = PairingComparison(code: code, attempt: mine, session: serial)
            comparedSession = session
            phase = .comparing(code: code)
        case .paired(let peer):
            clearComparison()
            await directory.paired(peer)
            var deviceName = phone?.deviceName
            if deviceName == nil { deviceName = await directory.deviceName(peer.id) }
            guard mine == attempt else { return }
            name = FriendNameSuggestion.from(deviceName: deviceName) ?? ""
            phase = .naming(peer)
        case .failed(let failure):
            clearComparison()
            phase = .failed(failure)
        }
    }

    private func streamEnded(attempt mine: Int) {
        guard mine == attempt else { return }
        session = nil
        events = nil
        clearComparison()
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
