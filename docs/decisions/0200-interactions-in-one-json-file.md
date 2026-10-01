# ADR 0200: Interactions persist in one JSON file

- Status: Proposed
- Date: 2026-09-30
- Owner: P15-A (Shell and IA)

## Context

ADR 0011 decision 6 leaves the `InteractionStore` storage to the shell lane. The store holds every `Interaction` on the phone: live ones that Home shows and `SkillService.restore(_:)` needs at launch, and finished ones that feed Friends' history and a plan's "How this came together".

What the data looks like:

- `Interaction` is a `Codable` value type, already frozen in StarlingCore with its own validation on decode (`Plan`, `PlaceName`, `PeerID`).
- A phone has tens of interactions a week, not thousands. Every screen reads all of them anyway (Home groups them, Friends filters them by participant).
- Writes come from one place, the lifecycle coordinator (ADR 0201), one event at a time.
- The app must read the store in the background: App Intents (ADR 0018 decision 4) and a later notification action.

Options considered:

1. **SwiftData.** `@Model` "converts a Swift class into a stored model". That means a mirror class for every nested value (`InteractionState`, `SkillProposal`, `Artifact`, `EgressRecord`), a second validation path, and a model context to pass between actors. It earns its place for large, queried, related data, which this is not.
2. **SQLite directly.** No Starling package depends on it, and nothing here needs queries.
3. **One JSON file**, the pattern `FileRulesStore` already ships for the owner's rules.

## Decision

1. **`FileInteractionStore`** (StarlingFeatures) keeps every interaction in `Application Support/Starling/interactions.json`, as `{"version": 1, "interactions": [...]}`, cached in memory and written through on each change. The version field lets a later build migrate.
2. **Writes are atomic, protected until first unlock, and excluded from backup**, through a small `JSONFile` helper. `completeFileProtectionUntilFirstUserAuthentication` keeps the file encrypted until the owner first unlocks the phone after a restart, and still lets the app read it in the background afterwards. Excluding it from backup keeps plans, rosters, and the egress log on this phone, as the paired keys are (ADR 0003).
3. **A failed write leaves the cache unchanged**, so memory never disagrees with the file.
4. **An unreadable file is moved aside, not overwritten.** The store starts empty, records where the old file went (`quarantined`), and the app tells the owner. Starting empty loses Home's cards but never sends anything: a skill only acts on what `restore(_:)` hands it.
5. **History is bounded.** Live interactions are always kept. Of the finished ones (done or ended), only the newest 500 are kept.

## Consequences

- No new dependency, and the store is tested with `swift test` on the Mac like the rest of StarlingFeatures.
- Every write rewrites the whole file. At 500 finished interactions plus live ones, that is well under a megabyte. If history grows past that, the same protocol can move to SQLite without touching the coordinator.
- Peer cards, close friends, privacy topics, and contact links use the same `JSONFile` helper in their own files (ADRs 0201 and 0204).

## Sources

- `NSData.WritingOptions.completeFileProtectionUntilFirstUserAuthentication`, "An option to allow the file to be accessible after a user first unlocks the device": https://developer.apple.com/documentation/foundation/nsdata/writingoptions/completefileprotectionuntilfirstuserauthentication
- `URLResourceValues.isExcludedFromBackup`: https://developer.apple.com/documentation/foundation/urlresourcevalues/isexcludedfrombackup
- SwiftData `@Model`, "Converts a Swift class into a stored model": https://developer.apple.com/documentation/swiftdata/model()
- ADR 0003 (key storage), ADR 0011 (lifecycle and `InteractionStore`), `App/Features/Sources/StarlingFeatures/RulesStore.swift`
