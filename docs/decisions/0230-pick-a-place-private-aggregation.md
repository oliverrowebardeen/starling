# ADR 0230: Pick a place agrees on a venue by private aggregation over place queries

- Status: Accepted (code merged on main; status updated 2026-10-06)
- Date: 2026-10-01
- Owner: P15-D (Pick a place)

## Context

Brief 2.6.3 and 2.7: friends pick a place from private per-person limits (budget, diet, places to avoid) that nobody has to say aloud. Private constraints combine into a group answer, and nobody sees the others' inputs. ADR 0012 lets venues travel as `IssueValue.places` (1 to 8 `PlaceChoice`s) and the roster as `IssueValue.peers`. ARCHITECTURE rule 6 says code, not a model, enforces hard limits.

Facts about a venue are needed to judge it against a limit. Apple Maps does not have them. `MKMapItem` exposes a name, an identifier (iOS 18), a point-of-interest category, a phone number, a URL, a time zone, an address, and a location. It has no price level and no dietary information (MapKit documentation, verified 2026-10-01).

## Decision

1. **Protocol.** It uses the existing message bodies with `Envelope.skill = pick_a_place@1.0` and `Envelope.mode = invite` (Core v2.1, ADR 0020). An envelope in any other mode is ignored.
   1. **Ask.** The organizer sends `query(place, .places(candidates))` to each friend. Candidates are only the venues that fit the organizer's own limits, so those limits never leave the phone either.
   2. **Judge privately.** Each friend's phone looks up facts for each candidate itself (`PlaceSearching.facts(for:)`, by Maps identifier) and checks them against its owner's standing limits in code (`PlaceJudge`). It answers `answer(place, .places(acceptable))`, best first. This list is the only thing derived from the owner's limits that leaves the phone.
      - It is a yes or no to the organizer's own options, so the service passes the query in `OutboundContext.answering`, and the policy allows it under any topic choice to an on-device agent (ADR 0019, decision 4).
      - Within one launch a conversation answers about the candidate set of its first query only. Across launches, the conversation ledger caps it at 16 places per friend (ADR 0021): the Outbox reserves every candidate an answer covers, and the service reserves a no's candidates the same way before sending it.
      - Once a proposal is on the card, no query is answered again, so a friend who passed and one who has not decided look the same.
   3. **Choose.** The organizer picks the venue that fits the organizer and the most friends, then the lowest total rank, then its own order (`GroupChoice`). Friends it does not fit hear `reject(noOverlap)` and nothing else.
   4. **Propose.** `propose` carries `{place: one venue, people: roster}`, plus `time` and `activity` when the request was chained from a plan or a time. The roster starts with the organizer, so a friend's phone can tell who organized it after a restart.
   5. **Confirm.** Each person says yes with `accept`: the exact terms, naming a proposal the organizer sent them, and passing the proposal in `OutboundContext.accepting`, so the policy lets it through under any topic choice (ADR 0019, amendment 10).
      - **A pass sends nothing.** It looks exactly like silence (ADR 0017: "If you pass, they just won't see it"; ADR 0020, decision 9). Only yeses settle a friend before the confirm deadline. A pass, like silence, is left out at the deadline, and the shortened roster goes out on the same schedule either way.
      - **Taking a yes back** sends the ordinary no (`noOverlap`). It is final for that person: a later yes from them is ignored. The phone keeps it in the ledger and retries it until the organizer acknowledges it with an ordinary no, across relaunches, for at most a day. Until then the conversation answers nothing and sends only that no, and it is retired once the no is heard. Each retry names its interaction, after a relaunch too, so the consent sheet and the audit find it. Only an organizer acknowledges a rejection, so two phones never acknowledge each other's acknowledgments.
      - **Confirmation.** The organizer then sends `accept` with the same terms and the people who said yes. That roster may be smaller than the proposed one, never different. Everyone's coordinator then sees `everyoneConfirmed`, and the service reports `.produced(.placeChoice)` and `.produced(.attendees)` with the people who said yes.
      - **A withdrawal that crosses the confirmation wins.** The friend's phone has already ended, so the organizer sends everyone left the same terms with the shortened roster, and every phone records the new attendees. If nobody else is left, the organizer's plan fails.
      - No Pick a place message carries `declinedByOwner`. Rejections say only `noOverlap` or `expired`.
2. **Facts never come from a friend.** A friend's phone ignores everything about a candidate except its Maps identifier and the name, and it looks the identifier up itself. A name that differs from the lookup's is a conflict (`nameMismatch`), so a friend cannot pass a steakhouse's identifier off as "Green Garden Vegan". A typed place has no identifier, so its facts are unknown on every phone.
3. **Unknown is not a conflict.** A hard limit rejects a venue only on a known conflict. A budget with no known price, or a diet with no known menu, is reported as unchecked and ranks below known fits. Rejecting unknowns would reject every Apple Maps result whenever anyone sets a budget.
4. **An ordinary no, and a rate limit.** When nothing fits a friend, its phone replies `reject(noOverlap)`, creates no interaction, and shows its owner nothing. A proposal that no longer fits the owner's limits gets the same reply. A limit set to Never therefore looks like any other no (ADR 0019, decision 5).
   - Before Core v2.1 the phone stayed silent instead, so that a "none of these" could not leave without a consent sheet while a list needed one. Now a yes or no leaves without a sheet either way, so silence leaked the same fact, only slower, and made honest groups wait out the answer window.
   - To an organizer whose agent is not on its device, the phone stays silent. A no would need a consent sheet there, for a request its owner never saw.
   - Probing is bounded rather than prevented. Each friend may start at most 8 requests per hour on a phone, ended ones included, and the admission times survive a relaunch.
   - The organizer chooses when every friend has answered or when its answer window closes (15 minutes by default), whichever comes first. A pass on the consent sheet is silent, and the coordinator applies it.
5. **Descriptor changes from `SampleSkills.pickAPlace`.**
   - Only place is required, because organizing sends venue options (ADR 0019, decision 7).
   - People is used, because the roster travels. Time and activity are used, because a chained proposal repeats them.
   - Location, budget, and diet are used on the phone only, so Never on them does not block the skill.
   - It sends as an invite only, and it also produces `Attendees`.
   - It asks for no expiry: Compose keeps a request open until the plan's time, or the parent plan's start for a chained pick, clamped to 1 to 7 days (Oliver's device test, 2026-10-02).
6. **Restart.** The store keeps state and the current proposal. Anything with a proposal resumes:
   - The organizer re-proposes.
   - A friend who said yes says it again until confirmed.
   - A friend still deciding judges again when asked again.

   An organizer still collecting lists is reported as failed, because candidates and lists are in memory only.

   Every ending retires its conversation for good through `Outbox.retire(_:)` (ADR 0021), after any goodbye has gone, since retiring cancels sends in flight. A retired conversation is never answered or opened again, and an unreadable conversation ledger opens nothing. Restore retires ended interactions again, in case the app stopped first. A confirmed plan stays open for a shorter roster or a call-off; the organizer's owner, or a friend, can still withdraw it, which cancels confirmations still on their way and retires it. The ending is reported only after the retirement has succeeded, so a crash can never leave a reported ending open to a new request. If the retirement fails, the ending is reported as failed and the conversation stays closed for the launch. A yes taken back is the one ending reported before retirement: its withdrawal is written to the ledger first, that record blocks reopening across relaunches, and it is cleared only once the retirement succeeds.

   What must survive a relaunch is kept in a `PickAPlaceLedger` on the device (`UserDefaultsPickAPlaceLedger` in the app):
   - admission times, so the hourly limit does not reset;
   - each organizer's request expiry, recorded before its first query, and its confirm deadline, recorded before its proposal. A restored organizer keeps both, and one past either ends as expired before sending anything;
   - withdrawals waiting for the organizer's acknowledgment.

   The ledger fails closed. If it cannot be read or written, no request is admitted and no request is sent.
7. **Starting.** The coordinator applies `.started` and then calls `start` (ADR 0011, amendment 13); the service never emits it. Compose checks `PickAPlaceSkill.askable` first, because a `start` that throws ends the interaction as failed. With no friend whose card supports the skill, the service reports `.unsupported`.
8. **Limits on a peer.**
   - At most 4 requests per friend, 32 in total, and 8 new ones per friend per hour. Every admitted request holds its slot until the deadline an unanswered one would hold, however it ended, so a pass frees nothing sooner than a card left unanswered. The count comes from the admission times in the ledger, so a relaunch frees nothing either.
   - A request's admission is written to the ledger, and awaited, before anything is judged or answered. If it cannot be written, the request is dropped and its conversation retired (issue #65).
   - Every skill envelope is checked against the skill's major version, not only the first one in a conversation (issue #64).
   - The organizer counts a list only when it names a query it sent that friend in that conversation (issue #63).
   - A friend's request ends as expired once the organizer's answer window and three confirm windows have passed, so a silent organizer cannot hold a slot. A friend who said yes waits that long too.
   - The organizer's confirm deadline is an absolute time. When it passes, friends who have not answered are left out and told the request expired, whether or not the owner has tapped. The owner's yes then confirms with whoever said yes. If the owner has not said yes one confirm window after the deadline, the request ends as expired for everyone, so the phones always agree on whether there is a plan.
   - A friend's card changes only for a proposal newer than the last one to arrive: each new proposal takes a generation on arrival, and an older one whose checks resume late is dropped.
   - Only paired friends' messages are handled, and only their cards kept. A message for an unknown conversation starts nothing unless it is a place query.
   - A query from another major version gets no reply: the organizer leaves such a friend out from its card, and a reply per fresh conversation would let a friend make the phone send without limit.
   - A settled organizer repeats its confirmation at most 8 times per friend, and work for a conversation is dropped when it finishes.
9. **Sends and their steps** (ADR 0011, amendments 13 and 14).
   - Every send runs on a task tracked per conversation, and withdrawing, ending, or shutting down cancels it, so nothing leaves after the owner withdraws.
   - A denial or failure is reported only for a send made for the current step; when the organizer moves from asking to proposing, its queries are cancelled and their results dropped.
   - A denial that names a topic ends the request as blocked by privacy. A denial that names no topic is about one recipient (on-device only, or an unverified pairing). That friend is left out exactly as silence would leave them out: nothing more is sent to them, and the decision still waits for the answer window, so nobody can tell exclusion from silence (ADR 0020, decision 9).
   - A declined consent sheet adds no event: the coordinator applies the pass.
   - A second tap while a yes is on its way changes nothing. Passing after a yes is reported as withdrawn. A new proposal while this phone's list or yes is on its way is ignored, so the card never changes under the owner.

## Consequences

- Budget and diet values never cross the wire. Tests check every envelope over Loopback, and the consent sheet's items, through the real `DeterministicPolicyEngine`.
- The organizer learns each friend's acceptable subset of its own candidates and its order. That is the aggregation's disclosure, shown on the friend's consent sheet before it goes.
- **Real data is thin.** With Apple Maps as the only source, budgets are never checked and diets only through category kinds, so on device most limits are unchecked. The protocol and enforcement are complete. The card does not say "price not checked".
- The organizer's queries that are still waiting on consent sheets when it decides are cancelled. The coordinator closes those sheets with `consentCancelled` and applies the proposal it held meanwhile (ADR 0011, amendment 15).
- **Place set to Never still lets a friend join.** The friend's list goes as a yes or no, and their acceptance, which repeats only the organizer's terms, goes as a yes (ADR 0019, amendment 10). None of their own place values leave the phone.
- **One conversation, two organizers.** Invites are keyed by conversation. A co-invitee who knows a conversation ID could send its own query on it to another friend before the real organizer's query arrives, and receive that friend's list. Keying invites by organizer and conversation would put two interactions on one conversation, which `InteractionStore.interaction(conversation:)` cannot hold, so it stays keyed by conversation; lane F covers it as a scenario.
- A friend who is offline, or whom the policy excludes, still makes the organizer wait out the answer window. For a group at a table, the app may want a shorter window or a "Decide now" action (not built).
- The service emits no consent events. The coordinator owns them (ADR 0011, amendment 15).

## Sources

- `MKMapItem` (properties: name, identifier, pointOfInterestCategory, phoneNumber, url, timeZone, address, location): https://developer.apple.com/documentation/mapkit/mkmapitem
- `MKMapItem.identifier` (iOS 18): https://developer.apple.com/documentation/mapkit/mkmapitem/identifier-swift.property
- `MKMapItemRequest.init(mapItemIdentifier:)` (iOS 18) and `mapItem` (async): https://developer.apple.com/documentation/mapkit/mkmapitemrequest
- `MKPointOfInterestCategory`: https://developer.apple.com/documentation/mapkit/mkpointofinterestcategory
- Brief 2.6.3 and 2.7; ARCHITECTURE rules 6 to 8; ADRs 0011, 0012, 0014
- `Packages/Skills/PickAPlace/Sources/PickAPlace/` and its tests
