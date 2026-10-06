# Contributing to Starling

Starling is a research prototype. Contributions that help most right now:

- bug reports with the iPhone model, iOS version, build, and exact steps;
- tests, especially adversarial ones in `Tools/Simulator/Tests`;
- fixes to docs and small, focused code fixes.

For a new feature, a new skill, or a change to a shared interface, open an issue first so the design can be discussed before code is written.

Please report security problems privately, as described in [SECURITY.md](SECURITY.md), not in a public issue. Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Setup

Follow [Build and test](README.md#build-and-test) in the README. Package tests need only a Mac with Xcode 27; the app needs XcodeGen, and anything over Wi-Fi Aware needs two iPhones.

## Before you open a pull request

1. Run `Tools/test-all.sh`. It builds every package with warnings as errors and runs its tests. Run a single package with `Tools/test-all.sh StarlingCore` while you work.
2. Push your branch and run `Tools/local-gate.sh <branch>`. It merges `origin/<branch>` into `origin/main` in a throwaway worktree and runs the same checks as CI: every package's tests, the XcodeGen project and a Simulator build of the app, and the two Release checks (no test fakes and no Debug-only screens in Release). In a fork, keep your fork's `main` up to date first.
3. If your change touches behavior that only a device can show (radio, pairing, notifications, the on-device model), add numbered device steps to the pull request, for example: "Phone A: tap Add friend. Expect: a code within 2 seconds."

## Privacy rules

These are what make Starling's privacy claims true. A pull request that breaks one will not be merged.

- **Typed values only.** Peers send typed, bounded values (`Keyword`, `TimeSlot`, `MoneyAmount`, flags, counts), never free text. Do not add a `MessageBody` case or field that can carry free text.
- **No peer text in prompts.** Nothing that came from another phone goes into a model prompt except those typed values, presented as data. Venue names stay out of prompts entirely ([ADR 0231](docs/decisions/0231-venue-names-stay-out-of-prompts.md)).
- **Outbox and Inbox only.** Send only through `Outbox`, so the policy, consent, and the conversation ledger see every send. Receive only through `Inbox`. Never hold a `Transport` for sending, and never read `Transport.events` directly.
- **Code decides what leaves the phone.** `PolicyEngine` is deterministic; the model proposes, code enforces hard limits before and after every model call ([ARCHITECTURE section 2](docs/ARCHITECTURE.md#2-message-flow)).
- **Never stays on the phone.** A topic set to Never is not sent, under any skill ([ADR 0019](docs/decisions/0019-never-stays-on-the-phone.md)).

## Engineering rules

- Swift 6 language mode, strict concurrency, zero warnings.
- Anything that depends on the model sits behind `AgentModel` or `SkillModel` and is tested with `ScriptedAgentModel` or `ScriptedSkillModel` from `StarlingFakes`. Real-model tests are opt-in (`STARLING_MODEL_TESTS=1`).
- Do not commit the generated Xcode project. The app project comes from `App/project.yml`.
- Prefer waiting for an observable event or advancing an injected clock over sleeping in tests ([PROCESS.md, Test reliability](docs/PROCESS.md#test-reliability)).
- When you rely on a fact that changes over time (an API, an SDK version, a library's status), check it against a primary source and cite it.

## Interfaces and decisions

- `Packages/StarlingCore` holds the protocols and message types every package shares. Changes to `Envelope`, `MessageBody`, or a protocol requirement need an issue first, and wire format changes bump `Envelope.currentVersion` ([ARCHITECTURE section 3](docs/ARCHITECTURE.md#3-starlingcore-surface-v0-to-v2)).
- Record any decision with a real trade-off as an ADR in `docs/decisions/`, using the template in [the ADR index](docs/decisions/README.md), with primary sources. New ADRs take the next free number in the 0001 to 0099 series and start as Proposed.

## Commits and pull requests

- Work on a feature branch and open a pull request against `main`.
- One thing per commit: one feature, one fix, or one refactor. If a change can land in smaller steps that each build and pass, split it.
- Use conventional-commit prefixes (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:`), and write a body that explains why the change is needed, not only what it does.
- Fill in the pull request template, including tests run and any privacy impact.

## Writing style

- No em dashes or en dashes in any prose: docs, comments, commit messages, and UI copy.
- Plain, specific wording. App copy reads as plans with friends ([ADR 0017](docs/decisions/0017-copy-reads-as-plans-with-friends.md)).

## AI-assisted contributions

Starling itself was built with AI coding agents ([PROCESS.md](docs/PROCESS.md)), and AI-assisted contributions are welcome. You are responsible for every line you submit: run the tests, read the diff, and make sure it follows the rules above.

## License

By contributing, you agree that your contribution is licensed under the [Apache License 2.0](LICENSE), as section 5 of the license describes. There is no separate contributor agreement. You may add your name to [AUTHORS](AUTHORS) in your first pull request.
