# Simulator

A Mac-only Swift package that runs several Starling agents in one process over the in-memory Loopback transport. It has two jobs:

- **`starling-sim`**, a command-line tool that runs short scripted scenarios (discovery, propose and accept, replays, reordering, stale and future-dated messages, a forged sender, impersonation over the secure channel, garbage bytes) and prints each transcript.
- **The adversarial test suite**, which is most of the package's value. It drives the real skill services, the policy, the secure channel, and the app's lifecycle coordinator against hostile peers, with deterministic seeds and virtual time ([ADR 0150](../../docs/decisions/0150-adversarial-test-method.md), [ADR 0250](../../docs/decisions/0250-phase-1-5-adversarial-contracts.md)).

No device or radio is involved. Wi-Fi Aware and LocalP2P behavior is tested on iPhones (see `docs/checklists/`).

## Run

From the repository root:

```sh
swift run --package-path Tools/Simulator starling-sim --help        # list scenarios
swift run --package-path Tools/Simulator starling-sim all           # run every scenario
swift run --package-path Tools/Simulator starling-sim replay --agents 4
```

## Test

```sh
Tools/test-all.sh Tools/Simulator
```

| Target | What it covers |
|---|---|
| `SimulatorKitTests` | The simulation itself, including agents over the secure channel |
| `ScenarioTests` | Every scenario, envelope fuzzing, PSI abuse, and consent bypass attempts |
| `DownIntegrationTests` | Phase 1's Down? negotiation and the policy together, including a malicious peer |
| `Phase15RedTeamTests` | Phase 1.5's skills, plan changes, the conversation ledger, audit, and app wiring under attack |
| `PromptInjectionTests` | Paired injection measurements against the real on-device model. Opt-in: `STARLING_MODEL_TESTS=1`, on a Mac with Apple Intelligence; add `STARLING_INJECTION_REPORT=<path>` to save the JSON report. Results are in [`Tests/PromptInjectionTests/Results`](Tests/PromptInjectionTests/Results/README.md). |

## Layout

- `Sources/SimulatorKit`: the simulation: agents on one Loopback hub with seeded peer IDs, optional latency, and bare or secure-channel links.
- `Sources/starling-sim`: the command-line tool.
- `Scenarios/`: scenarios and attack helpers shared by the tool and the tests, including `AwakeWait`, the suspending-clock condition wait the tests use ([ADR 0258](../../docs/decisions/0258-simulator-waits-count-awake-time.md)).
- `Tests/`: the targets above.

Comments in these tests cite request files and lane codes from development; [PROCESS.md](../../docs/PROCESS.md#glossary) explains them.
