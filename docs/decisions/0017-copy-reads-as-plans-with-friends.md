# ADR 0017: Copy reads as plans with friends, not a dating app

- Status: Accepted
- Date: 2026-09-30
- Owner: Orchestrator

## Context

The device review found the main screen reading like a dating app: "Down?" with no activity, "How keen are you?", and "only if they're interested too". The Phase 1.5 prompt (section 9) listed banned words.

Oliver clarified on 2026-09-30 that the goal is tone, not a word list: Starling should not look like a dating app, and a crush feature could be fine sometime later, just not now. A hard ban would also block that future skill.

## Decision

1. **Plan words by default.**
   - "Down for…", always with the activity: Down for boba, Down for a walk. There is no Down screen without an activity.
   - "up for it", "both down", "It's a plan", "All 3 of you said yes".
   - Mutual reveal: "If nobody's up for it, nobody sees you asked."
   - Declining: "If you pass, they just won't see it."
2. **Real friends wherever a request goes out.** Show the friends' pair symbols and names (DESIGN.md), not abstract counts. "Checking with 4 friends" is fine as status; the audience picker shows who.
3. **No word list in code.** Tone is reviewed by eye in each lane's PR and in the device checklists. Words like "match" are not forbidden; in the current skills, plan wording simply reads better. For example, the status mark's VoiceOver labels "Looking for a match" and "Matched" become "Checking with friends" and "It's a plan".
4. **One line where a rule needs explaining.** For example, You's note on time and activity: "Time and activity are always shared as the overlap. Nothing can line up without them."
5. **No em dashes** in any user-facing copy (owner norm).

## Consequences

- The first-run and main screens read as making plans with friends.
- A future skill with different needs, a crush skill for example, can choose its own words without fighting a lint rule. It would still go through the skill registry, consent, and mutual reveal like any other.

## Sources

- Phase 1.5 prompt, section 9; Oliver's clarification in conversation, 2026-09-30
- Mockups "Home", "New", and "It's a plan"
