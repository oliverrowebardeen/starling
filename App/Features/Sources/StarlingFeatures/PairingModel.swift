import Foundation
import Observation
import StarlingCore

/// Starts a `PairingSession`. Starting one is the implementing lane's API
/// (E1 for the key exchange, E2 for the Wi-Fi Aware link), so the app takes
/// a factory. Until they merge, Debug builds pass `ScriptedPairingSession`.
public typealias PairingSessionFactory = @Sendable () async throws -> any PairingSession

/// Drives the in-person pairing ceremony: show the code, both people
/// compare, confirm or cancel, then name the friend.
@MainActor
@Observable
public final class PairingModel {
    public enum Phase: Hashable, Sendable {
        case idle
        case starting
        /// Both phones show this code. Pairing continues only if both match.
        case comparing(code: String)
        case confirming
        /// Keys are pinned. The owner names the friend before it is saved.
        case naming(PairedPeer)
        case paired(PairedPeer)
        case failed(PairingFailure)
    }

    public private(set) var phase = Phase.idle
    public var nickname = ""
    public private(set) var notice: String?

    private let makeSession: PairingSessionFactory
    private let store: any PairedPeerStore
    private var session: (any PairingSession)?
    private var events: Task<Void, Never>?
    /// Set when the pairing screen went away, so a session that is still
    /// being created is cancelled as soon as it exists.
    private var isEnded = false

    public init(makeSession: @escaping PairingSessionFactory, store: any PairedPeerStore) {
        self.makeSession = makeSession
        self.store = store
    }

    public func start() async {
        switch phase {
        case .idle, .paired, .failed: break
        default: return
        }
        phase = .starting
        notice = nil
        do {
            let session = try await makeSession()
            if isEnded {
                await session.cancel()
                phase = .failed(.cancelled)
                return
            }
            self.session = session
            events = Task { [weak self] in
                for await event in session.events {
                    self?.handle(event)
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
        phase = .confirming
        await session.confirm(codesMatch: codesMatch)
    }

    public func cancel() async {
        guard let session else {
            phase = .idle
            return
        }
        await session.cancel()
    }

    /// The pairing screen went away, for example swiped down. Cancels a
    /// ceremony in progress so it does not keep running with no screen;
    /// a finished pairing is left alone.
    public func end() async {
        isEnded = true
        switch phase {
        case .starting, .comparing, .confirming:
            await session?.cancel()
        case .idle, .naming, .paired, .failed:
            break
        }
    }

    /// Saves the friend under the chosen nickname. The store replaces any
    /// record with the same key, so saving after the session pinned the peer
    /// only updates the name.
    public func saveNickname() async {
        guard case .naming(let peer) = phase else { return }
        do {
            let named = try PairedPeer(publicKey: peer.publicKey, nickname: nickname, pairedAt: peer.pairedAt)
            try await store.save(named)
            phase = .paired(named)
            notice = nil
        } catch is ValidationError {
            notice = "Use 1 to \(PairedPeer.maxNicknameCharacters) characters."
        } catch {
            notice = "Couldn't save your friend. Try again."
        }
    }

    public func reset() {
        isEnded = false
        events?.cancel()
        events = nil
        session = nil
        nickname = ""
        notice = nil
        phase = .idle
    }

    func handle(_ event: PairingEvent) {
        switch event {
        case .confirmCode(let code):
            phase = .comparing(code: code)
        case .paired(let peer):
            nickname = peer.nickname
            phase = .naming(peer)
        case .failed(let failure):
            phase = .failed(failure)
        }
    }

    private func streamEnded() {
        session = nil
        events = nil
        switch phase {
        case .starting, .comparing, .confirming:
            // The session ended without a result.
            phase = .failed(.protocolError)
        default:
            break
        }
    }

    /// What to tell the owner about a failure.
    public static func message(for failure: PairingFailure) -> String {
        switch failure {
        case .codeMismatch:
            "The codes didn't match, so Starling didn't pair. If you picked the right phone, someone nearby may be interfering. Try again somewhere else."
        case .cancelled:
            "Pairing was cancelled."
        case .timedOut:
            "Pairing took too long. Keep both phones close and try again."
        case .transportFailed:
            "Starling couldn't reach the other phone. Keep both phones close and try again."
        case .protocolError:
            "The other phone answered in a way Starling didn't expect. Make sure both phones have the latest Starling and try again."
        }
    }
}
