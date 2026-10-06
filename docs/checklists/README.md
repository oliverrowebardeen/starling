# Device checklists

These are the numbered steps each lane left for running its work on real iPhones, since no test can exercise the radio, pairing between phones, or the on-device model end to end; the terms are defined in the [PROCESS.md glossary](../PROCESS.md#glossary).

- [`phase-0-device.md`](phase-0-device.md): first-time setup (Xcode, XcodeGen, signing, Developer Mode) and the LocalP2P link test, including the one-iPhone-plus-Mac variant with `Tools/Peer`.
- `phase-1.5-*.md`: the current checklists, one per Phase 1.5 lane. Start with [`phase-1.5-P15-G.md`](phase-1.5-P15-G.md) (pairing) and [`phase-1.5-P15-A.md`](phase-1.5-P15-A.md) (the app's screens).
- `phase-1-*.md`: Phase 1 checklists, kept as history. Some describe screens that Phase 1.5 replaced, such as onboarding ([ADR 0202](../decisions/0202-first-use-permissions-and-no-onboarding.md)).

Most checklists call the phones Phone A and Phone B. Run Debug builds: Down for... and the You › Developer section exist only in Debug.
