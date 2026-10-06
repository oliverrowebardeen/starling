# ADR 0202: No onboarding; Local Network and notifications at first use

- Status: Accepted (code merged on main; status updated 2026-10-06); decision 3 amended by ADR 0260
- Date: 2026-10-01
- Owner: P15-A (Shell and IA)

## Context

Phase 1 opened on a four-step onboarding: welcome (with a test-build notice), Local Network, notifications, then a rules form. ADR 0013 moves every permission to the moment the owner uses the feature that needs it: Local Network "at the first Pair or the first request", notifications "when the owner sends a first request". ADR 0015 says no screen opens on a settings form, and moves test-build notices to the Debug-only Developer section.

iOS has no API to ask for Local Network access or read its state. The alert appears on the first local network operation, such as browsing for a Bonjour service (TN3179). Starling's radios browse as soon as they start, so starting them at launch would show the alert at launch.

## Decision

1. **No onboarding.** The app opens on Home. With no friends, Home says "Pair with a friend in Friends, then tap New to make a plan." The rules editor moves to You › Your rules.
2. **The radios wait for Local Network to be asked.** At the first Pair (Friends › Add friend) or the first request (New's start button), the app runs the deliberate Bonjour browse that shows the alert, records that it asked (`OwnerSettings.localNetworkAsked`), and starts the radios. From then on the radios start at launch. Before that nobody is paired, so no friend could reach this phone anyway.
3. **Notifications are offered after the first request**: "Want a heads-up when friends are up for it?" with Turn on and Not now. Only Turn on shows the system alert. The answer is recorded so it is offered once.
4. **What notifies.** A proposal ready, a plan made, or a friend's question. Never an ending, and never a friend's mutual-reveal request before it is mutual (brief 2.6), the same rule Home follows.
5. **Skill permissions** go through `PermissionGate` and Starling's one-button sheet (ADR 0013): calendar when Find a time starts, location when the owner taps "Suggest places near me" in Pick a place, photos after a plan ends (lane E). A permission whose access API has not merged is reported unavailable, and the skill takes its no-permission path.

## Consequences

- First launch shows no system alert at all.
- The first Find a time request can show two alerts in a row (Local Network, then Starling's calendar sheet and the calendar alert). That happens once.
- Phase 1 testers who already finished onboarding have `localNetworkAsked` false after updating, so their radios wait for the next Pair or request. The alert does not reappear: iOS remembers the answer, and the deliberate browse simply succeeds.

## Sources

- TN3179, Understanding local network privacy: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- `UNUserNotificationCenter.requestAuthorization(options:completionHandler:)`: https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/requestauthorization(options:completionhandler:)
- HIG, Privacy (request permission when the feature is used): https://developer.apple.com/design/human-interface-guidelines/privacy
- ADRs 0013, 0015, 0142 (Phase 1 consent and permission UX, which this replaces for permissions)
