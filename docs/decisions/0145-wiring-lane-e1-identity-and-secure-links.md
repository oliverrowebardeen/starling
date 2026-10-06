# ADR 0145: Wiring lane E1's identity, pins, pairing, and secure links

- Status: Accepted (code merged on main; status updated 2026-10-06); decisions 2 and 4 amended by ADR 0260
- Date: 2026-10-01
- Owner: H (App features)

## Context

Lane E1 is merged (PR #16). `docs/requests/E1.md` item 2 sets the app's side: load the identity from the Keychain, keep friends in the Keychain paired-peer store, create exactly one `PinAuthority` and share it with every `SecureTransport` and `PairingService` (ADR 0100 decision 11), wrap each link (LocalP2P and Wi-Fi Aware) with key-derived `PeerID`s, start each pairing service after its transport and keep it alive, pair with `pair(with:nickname:)`, reconnect each transport after `.paired`, and unpair only through the authority or `SecureTransport.unpair`.

Three gaps between that API and the app:

1. The app has one `Outbox` and one `Inbox` loop, but E1 gives one `SecureTransport` per link.
2. `pair(with:)` needs the friend's `PeerID`, and nothing public reports a nearby phone that is not pinned yet (`docs/requests/H.md` request 5).
3. There is no rename through the authority, and E1 forbids writing the store directly.

## Decision

1. **One composite transport** (`CompositeTransport`, in `StarlingFeatures`) merges the secure transports behind the app's single `Outbox` and `Inbox`. A peer is announced when its first link comes up and lost when its last goes; a send goes to a link where the peer is available, newest first, failing over to the next.
2. **A link watcher** (`LinkWatcher`) wraps each raw link before its `SecureTransport`, passes every event through, and records the peers the link reports. The pairing screen lists those that are neither pinned nor this phone, with this phone's short ID so both owners can tell the phones apart. The ID is the link hello's claim; E1's ceremony proves the key, and a wrong pick ends in mismatched codes with nothing pinned. The owner chooses; the app never auto-picks the first unpinned peer, which E1 calls fragile with several phones nearby. Lane E2's `WiFiAwareTransport.peerID(for:waitingUpTo:)` (PR #38) now resolves the device picked in "Find a friend's phone" to its `PeerID`, which the screen selects (waiting up to 15 seconds for the link hello); the watched list remains for LocalP2P and for the phone that made itself discoverable, which gets no picker callback.
3. **`SecureLinks`** builds the stack for Release and Debug: Keychain identity, one `PinAuthority`, Wi-Fi Aware (where `WiFiAwareSupport.isSupported`) and LocalP2P links with the identity's `PeerID`, each watched, wrapped, and given a `PairingService`, then the composite and one `Inbox`. Pairing services start after the transports (`AppServices.afterStart`) and are held by the app's services for its lifetime.
4. **Pairing order follows E1**: choose the phone and the nickname, then compare codes; E1 commits the pin. After `.paired` the app calls `reconnect` on every secure transport. **Both phones run the ceremony on the same link** (`PairingRoute`): Wi-Fi Aware once it reports the friend, waiting up to five seconds for it, otherwise the first link that does. The link does not depend on which list entry the owner tapped, because each link has its own PairingService and a ceremony on one never hears the other.
4a. **The agent card offers only what the build runs.** `AppModel` builds it from the model's location, adding `.down` and `.psi` only when a Down service exists, so Release (no Down) never draws a friend's Down into a negotiation it cannot answer.
5. **Unpair goes through `authority.unpair`.** `FriendsModel` no longer touches the store. **Rename goes through `PinAuthority.rename`** (lane E1, #36) in every build: it runs under the pin lock and refuses a friend being unpaired, so it cannot restore a removed pin.
6. **The link layer is one component** (`LinkTestModel`) on the app's `Outbox` and Inbox loop: it greets each newly available peer with a `hello` (what lane F expects), answers each `hello` it did not start once, and shows connection state and round trips. Only one Wi-Fi Aware transport exists, the app's (ADR 0111).
6a. **The radios start after onboarding's Local Network step.** `AppModel.start()` opens the Inbox loop with the radios off; `startLinks()` starts them, from onboarding's Local Network step on first run or at launch once onboarding is done, because their Bonjour work raises the Local Network alert (ADR 0142).
7. **Services are built in a launch task** (`Bootstrap`), because the identity loads asynchronously. If the Keychain cannot be read the app stops with a plain message and Try again instead of running on a made-up identity; an unsigned build (`KeychainError` -34018) is told it needs signing.
8. **Debug uses the same stack** plus the simulated friend, which now has its own E1 identity and `PinAuthority` and joins over a `SecureTransport` on the in-process Loopback hub. It and sample friends live in an in-memory overlay on the Keychain store, never written to the Keychain.

## Consequences

- Release now has real pairing, friends, unpair, and secure links, but still no Down (ADR 0144: the only PSI provider is in `StarlingFakes`).
- Simulator runs need a signed build (Sign to Run Locally) to reach the Keychain; CI's unsigned build only compiles.
- The Phase 0 Nearby screen (Debug only) runs its own LocalP2P transport alongside the app's, so it can appear in the app's "Phones nearby" list with a random ID. It is a Phase 0 tool and can be removed once E1's links cover its use.
- Issue #32 (an unpair can stall behind a stuck cancellation send) is E1's to fix; no app change.

## Sources

- `docs/requests/E1.md` item 2; ADR 0100, ADR 0101 (lane E1).
- ADR 0111 (one publish per service per device); ADR 0144 (Down wiring); ADR 0143 (link test before E1, superseded in part by decision 6).
