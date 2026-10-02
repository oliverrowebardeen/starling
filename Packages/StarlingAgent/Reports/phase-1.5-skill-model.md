# Phase 1.5 skill model quality: macOS baseline

Lane P15-B results for `SkillModel` (ADR 0212), measured with the real on-device model on the owner's Mac: macOS 26.7 (25G229), Xcode 27.0, `apple.system`, context 4096 tokens, token counts from `tokenCount(for:)`, greedy sampling, a fresh session per call, on 2026-10-01 while other lanes were building on the same Mac. This is the macOS 26 model, not the iOS 27 models; `docs/checklists/phase-1.5-P15-B.md` part A covers the phone. Per ADR 0016 these numbers are a baseline, not a release gate.

How to reproduce, from `Packages/StarlingAgent`:

- `swift run -c release agent-bench --routing` and `--routing --held-out`
- `swift run -c release agent-bench --chips` and `--chips --held-out`

The routing and chip sets (`StarlingAgentBench/SkillSets.swift`) and their held-out sets were written together, before any measurement, by one author. The held-out sets were never used to choose a change (ADR 0160).

## Summary

| Measure | First run | Final |
|---------|----------:|------:|
| Routing, tuning set (40) | 32 / 40 | 36 / 40 |
| Routing, held-out set (20) | not run | 19 / 20 |
| Requests routed to none (tuning / held-out) | 0 | 0 / 0 |
| Non-requests routed to a skill (tuning / held-out) | 1 | 2 / 1 |
| Down for... chips all right, tuning set (20) | 12 / 20 | 16 / 20 |
| Down for... chips all right, held-out set (10) | 5 / 10 | 6 / 10 |
| Invented activities (tuning / held-out) | 1 / 1 | 0 / 1 |
| Worst routing call | 447 tokens | 611 tokens |
| Worst chips call | 1,791 tokens | 1,811 tokens |
| Median routing latency | 825 ms | 496 ms |

Every call fits ADR 0002's 2,048-token budget. The held-out chip numbers in the "First run" column were measured after the first round of changes, not before any; it is the only held-out run before the final one.

What changed between the columns, each chosen from tuning-set failures only:

1. **Routing prompt from descriptor data.** Each skill is described by its name, summary, what its building block does, and every slot hint, not the summary alone (32 to 34). Then one instruction: a named activity to do soon goes to the skill that checks who is up for it, and a where or when skill only when the owner asks where or when (34 to 36, at the cost of one more non-request routed to a skill).
2. **Chip grounding.** Days and group words ("friends") are never activities; a name is never a word the owner used for an activity or a place; "nearby" stands for "far" or "near" ("nothing far"); "close friends" is never a place.
3. **Two labels widened**, which inflates the tuning number: "nothing far" and "not too far" now accept "nearby" (the mockup's chip for those words is "Nearby"), and "study session at the library" expects the library as a place.

## Routing, final

### Tuning set

| Expected | Correct |
|----------|--------:|
| down_for | 14 / 14 |
| find_a_time | 9 / 10 |
| pick_a_place | 7 / 8 |
| none | 6 / 8 |
| **all** | 36 / 40 (90%) |

Misses: "pick a day next week for game night" to pick_a_place; "find a vegetarian spot for dinner tonight" to find_a_time; "never share my location" and "how do I pair a new friend" to down_for.

### Held-out set

| Expected | Correct |
|----------|--------:|
| down_for | 7 / 7 |
| find_a_time | 4 / 4 |
| pick_a_place | 4 / 4 |
| none | 4 / 5 |
| **all** | 19 / 20 (95%) |

Miss: "good morning" to down_for.

The failure direction matters. A request routed to none falls back to the skill tiles; a non-request routed to a skill shows chips the owner dismisses. Nothing is sent before the owner taps the start button (ADR 0016, decision 2), so neither failure leaks anything.

## Chips, final

- Model: `apple.system`, 20 labeled utterances, 0 failed calls, 0 invented activities
- Worst call: 1811 tokens

| Chip | Correct | Accuracy |
|------|--------:|---------:|
| days | 20 / 20 | 100% |
| times | 20 / 20 | 100% |
| wants | 19 / 20 | 95% |
| avoids | 20 / 20 | 100% |
| budget | 20 / 20 | 100% |
| place | 19 / 20 | 95% |
| audience | 18 / 20 | 90% |
| names | 20 / 20 | 100% |
| **all chips** | 16 / 20 | 80% |

| # | Utterance | Wrong chips | Got |
|--:|-----------|-------------|-----|
| 3 | dinner tonight under $20 with Maya and Jake | wants | day +0; 18-24; $20; with Maya, Jake |
| 4 | who wants to play basketball this afternoon | audience | day +0; 12-17; wants basketball |
| 5 | karaoke friday night with close friends | audience | day +3; 18-24; wants karaoke; ask everyone |
| 16 | ramen near downtown on thursday | place | day +2; 0-24; wants ramen; place nearby |

### Held-out set

- Model: `apple.system`, 10 labeled utterances, 0 failed calls, 1 invented activities
- Worst call: 1811 tokens

| Chip | Correct | Accuracy |
|------|--------:|---------:|
| days | 10 / 10 | 100% |
| times | 9 / 10 | 90% |
| wants | 9 / 10 | 90% |
| avoids | 10 / 10 | 100% |
| budget | 10 / 10 | 100% |
| place | 10 / 10 | 100% |
| audience | 8 / 10 | 80% |
| names | 9 / 10 | 90% |
| **all chips** | 6 / 10 | 60% |

| # | Utterance | Wrong chips | Got |
|--:|-----------|-------------|-----|
| 1 | who's up for bowling tonight | audience | day +0; 18-24; wants bowling |
| 2 | hot pot tonight with Sam, under $25 | wants, names | day +0; 18-24; wants hot pot, sam; $25 |
| 3 | quick coffee before 3 today | times | day +0; 15-24; wants coffee |
| 6 | pizza friday with close friends, no pineapple | audience | day +3; 0-24; wants pizza; avoids pineapple; ask everyone |

Remaining failure modes:

- **Audience.** "who wants to play basketball" and "who's up for bowling" are not read as everyone, and "close friends" comes back as everyone. Audience parsing is being redone with Core v2.1's audience cases (everyone except, groups), so it was left as is.
- **A name as an activity** ("hot pot tonight with Sam" wanted "sam"), held-out only, so not fixed here.
- **Times.** "before 3 today" became 15 to 24 instead of up to 15 (held-out only; the same Grounding code as ADR 0161).
- **A dropped activity.** "dinner tonight under $20 with Maya and Jake" lost "dinner".

## Proposal sentence

One live sample, with typed facts (Maya, Jake, boba, 8:30 PM tonight, a place), passed every check: "Maya and Jake are planning to meet at Boba Guys tonight at 8:30 PM for boba. Does that work for you?" The place was filled in by code from the `{place}` placeholder; the venue name never reached the prompt. Any sentence that fails a check is replaced by the template (`ProposalTemplate` in the Down for... package).

## Core v2.1 round (2026-10-01)

Core v2.1 (ADR 0020) adds send modes and new audience cases, so the chip schema gained a mode field and an `everyoneExcept` audience. The chip sets gained three tuning items and two held-out items for them, written together before either was measured. Same Mac, same model.

| Measure | Before this round | After |
|---------|------------------:|------:|
| Chips all right, tuning set | 16 / 20 | 20 / 23 |
| Chips all right, held-out set | 6 / 10 | 6 / 12 |
| Mode chip, tuning / held-out | n/a | 23 / 23, 12 / 12 |
| Worst chips call | 1,811 tokens | 2,021 tokens |
| Routing, tuning set (prompt unchanged) | 36 / 40 | 36 / 40 |

- The first run with the mode field reached 2,084 tokens, over ADR 0002's 2,048. Shorter field descriptions and instructions brought it to 2,021.
- From the tuning set only: the small model files the friend in "everyone except Jake" under avoids. Code now moves an avoid that follows "everyone except" or "everyone but" into the left-out names; "anything but sushi" stays an avoid.
- Held-out misses that remain: a group's name ("the climbing crew") read as an avoid; "who's up for" not read as everyone; "close friends" read as everyone; "Sam" read as an activity; "before 3" as 15 to 24.
- The proposal sentence now gets the time as a `{time}` placeholder, like the place (review of PR #56, finding 7); a sentence with any time of its own is refused. One live sample after the change wrote "at {time}", which code folds into "tonight at 8:30 PM".
- `SkillModel` cannot see the friends list, and `ParsedIntent` has no field for left-out names or a group, so names follow a convention for now: with `everyoneExcept([])` they are the friends left out, and a group's name arrives among them. `docs/requests/P15-B.md` asks for fields.

### Chips, tuning set

- Model: `apple.system`, 23 labeled utterances, 0 failed calls, 1 invented activities
- Worst call: 2021 tokens

| Chip | Correct | Accuracy |
|------|--------:|---------:|
| days | 23 / 23 | 100% |
| times | 23 / 23 | 100% |
| wants | 22 / 23 | 96% |
| avoids | 23 / 23 | 100% |
| budget | 23 / 23 | 100% |
| place | 22 / 23 | 96% |
| audience | 21 / 23 | 91% |
| names | 23 / 23 | 100% |
| mode | 23 / 23 | 100% |
| **all chips** | 20 / 23 | 87% |

| # | Utterance | Wrong chips | Got |
|--:|-----------|-------------|-----|
| 4 | who wants to play basketball this afternoon | audience | day +0; 12-17; wants basketball |
| 5 | karaoke friday night with close friends | audience | day +3; 18-24; wants karaoke; ask everyone |
| 16 | ramen near downtown on thursday | wants, place | day +2; 0-24; wants ramen, downtown; place nearby |

### Chips, held-out set

- Model: `apple.system`, 12 labeled utterances, 0 failed calls, 1 invented activities
- Worst call: 2018 tokens

| Chip | Correct | Accuracy |
|------|--------:|---------:|
| days | 12 / 12 | 100% |
| times | 11 / 12 | 92% |
| wants | 11 / 12 | 92% |
| avoids | 11 / 12 | 92% |
| budget | 12 / 12 | 100% |
| place | 11 / 12 | 92% |
| audience | 9 / 12 | 75% |
| names | 10 / 12 | 83% |
| mode | 12 / 12 | 100% |
| **all chips** | 6 / 12 | 50% |

| # | Utterance | Wrong chips | Got |
|--:|-----------|-------------|-----|
| 1 | who's up for bowling tonight | audience | day +0; 18-24; wants bowling |
| 2 | hot pot tonight with Sam, under $25 | wants, names | day +0; 18-24; wants hot pot, sam; $25 |
| 3 | quick coffee before 3 today | times | day +0; 15-24; wants coffee |
| 4 | beach tomorrow afternoon if anyone's around | place | day +1; 12-17; wants beach; place beach; ask everyone |
| 6 | pizza friday with close friends, no pineapple | audience | day +3; 0-24; wants pizza; avoids pineapple; ask everyone |
| 11 | invite the climbing crew to bowling saturday | avoids, audience, names | day +4; 0-24; wants bowling; avoids climbing; ask everyone; mode invite |

## Grounding round: chips in the owner's words (2026-10-02)

Oliver's device test found chips that were not his words: "movie night tonight in Elm Hall" showed the activity "Watch Movie", and "find a time invite for IKEA trip" showed "trip". ADRs 0161 and 0212 require every keyword chip to be the owner's words as typed: a span of the input, the whole phrase, in the owner's casing, never paraphrased, title-cased, or cut off, and never repeated across chips.

**What changed in the sets.**
- Both phrases and some like them went into the tuning and held-out sets together, before any measurement of them. Tuning added "movie night tonight in Elm Hall", "find a time invite for IKEA trip", "game night friday with Maya", "Costco run tomorrow afternoon", and "find a time for the Yosemite trip". Held-out added "trivia night tonight with Sam", "find a time for our NYC trip", "IHOP breakfast tomorrow morning", "karaoke night saturday", and "find a time for the Tahoe ski trip".
- Labels may now name a skill, so Find a time phrases are scored with Find a time's slots.
- Activity, avoid, and place chips are now scored exactly. The old word-subset match counted "trip" as "IKEA trip".
- A new "own words" chip checks that every keyword chip is a span of the message and that no word is in two chips.
- Labels that accepted a cut-off or reworded phrase were tightened to the owner's phrase, on both sets, for example "pickup soccer" not "soccer", and "nothing far" not "nearby". So these numbers do not compare with the earlier sections.
- One tuning label was corrected after the first run: Find a time offers only Invite, so it never shows a mode chip, and the IKEA trip label no longer expects one.

Same Mac, macOS 26.7 (25G229), `apple.system`, greedy sampling. The baseline is the code on main (7d279e4) with the new sets.

| Chips, tuning set (28) | Baseline | Final |
|---|--:|--:|
| Activity | 21 | 28 |
| Avoids | 28 | 28 |
| Place | 24 | 28 |
| Own words | 23 | 28 |
| Mode | 27 (one wrong label) | 28 |
| Days, times, budget, names | 28 each | 28 each |
| Audience | 26 | 26 |
| **All chips** | **16** | **26** |

| Chips, held-out set (17) | Baseline | Final |
|---|--:|--:|
| Activity | 11 | 15 |
| Avoids | 16 | 17 |
| Place | 14 | 17 |
| Own words | 15 | 17 |
| Names | 14 | 16 |
| Times | 16 | 16 |
| Audience | 14 | 14 |
| Days, budget, mode | 17 each | 17 each |
| **All chips** | **5** | **12** |

- Invented activities: 3 to 0 on tuning, 2 to 1 on held-out. Worst call: 2,046 tokens, within ADR 0002's 2,048.
- Remaining activity misses, held-out only:
  - "find a time for our NYC trip": the model gave no activity, and code never adds one.
  - "invite the climbing crew to bowling saturday": the model filed "climbing" as the activity and dropped the group's name.
- Audience is still the weakest chip, as before ("who's up for", "close friends").
- An earlier wording of the prompt asked for "the owner's exact words ..., the whole phrase as typed". It scored 26 / 28 and 12 / 17 too, but its worst call was 2,080 tokens, over the budget, so the shorter wording above was kept. Neither was chosen by held-out results.

| Routing | Before | After |
|---|--:|--:|
| Tuning (43, with "movie night tonight in Elm Hall", "Costco run tomorrow afternoon", and "find a time invite for IKEA trip") | 38 / 43 | 38 / 43 |
| Held-out (22, with "trivia night tonight with Sam" and "find a time for our NYC trip") | 21 / 22 | 21 / 22 |

The routing prompt did not change, and both device-test phrases route right. "Costco run tomorrow afternoon" routes to none: the model sees no plan with friends in it.
