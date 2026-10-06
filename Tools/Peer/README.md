# Peer

`starling-peer` is a Mac command-line stand-in for a second phone. It discovers nearby devices over LocalP2P (Bonjour, with optional peer-to-peer Wi-Fi), sends a typed test proposal, accepts incoming proposals, and reports round-trip times.

It talks only to the app's **Nearby** screen, which exists in Debug builds only (You › Developer › Nearby). That screen and this tool use the Phase 0 link test: unauthenticated, unencrypted, with an allow-all policy from `StarlingFakes`. Neither uses pairing or the secure channel, so `starling-peer` cannot talk to the app's friends, skills, or plans, and nothing personal should be sent over it.

## Run

From the repository root, on macOS 26 or later:

```sh
swift run --package-path Tools/Peer starling-peer           # Bonjour and peer-to-peer Wi-Fi
swift run --package-path Tools/Peer starling-peer --no-p2p  # without peer-to-peer Wi-Fi
```

Allow Local Network access if macOS asks. Then type:

| Command | What it does |
|---|---|
| `list` | Shows discovered phones, numbered |
| `send <number or ID prefix>` | Sends a test proposal; the phone accepts and the round trip is timed |
| `stats` | Prints round-trip statistics |
| `quit` | Stops the session |

On the phone, open You › Developer › Nearby and tap Start. Steps and expected results are in [the Phase 0 device checklist](../../docs/checklists/phase-0-device.md), section "A (variant). One iPhone plus this Mac".

## Test

```sh
Tools/test-all.sh Tools/Peer
```
