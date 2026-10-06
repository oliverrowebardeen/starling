# Security policy

Starling is a research prototype. It has not had an independent security audit, and it is not distributed through the App Store. The reviews it has had are described in the [threat model](docs/THREAT_MODEL.md), section 6.

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's private vulnerability reporting: open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue, pull request, or discussion for a vulnerability.

Please include:

- what an attacker can do, and which guarantee it breaks;
- the commit you tested;
- steps or a test that reproduces it (a test in `Tools/Simulator/Tests` is ideal);
- whether it needs a paired friend, a nearby device, or code on the victim's phone.

This is a volunteer-maintained project. Reports are handled on a best-effort basis; you will get an acknowledgment and be kept informed while a fix is prepared. Please allow time for a fix before disclosing publicly.

## Supported versions

Only the `main` branch is supported. There are no releases.

## Scope

In scope:

- the secure channel, identity keys, and pairing (`Packages/StarlingIdentity`);
- the policy and consent layer (`Packages/StarlingPolicy`) and the `Outbox` and `Inbox` choke points (`Packages/StarlingCore`);
- envelope decoding and validation, replay and age checks;
- any way a peer can make data leave a phone without the owner's consent, start a skill or a permission prompt on another phone, or learn more than the threat model says it can;
- prompt injection through values a peer sends;
- skill protocols (Down for..., Find a time, Pick a place, Change the plan) diverging or leaking between friends.

Known limits, documented in the [threat model](docs/THREAT_MODEL.md) sections 5 and 5a, are not new vulnerabilities, though better attacks against them are welcome. They include:

- `InsecurePSIStub` reveals one side's set to the other. It exists only in Debug builds, which is why Down for... runs only in Debug.
- An agent's model locality is self-declared.
- Metadata (who talks to whom, when, and how much) is visible to nearby observers.
- The organizer of a group step is trusted to report its outcome.

Out of scope: attacks that need an unlocked phone, a jailbroken device, or a compromised OS; and the Debug-only Developer screens, including the unauthenticated Nearby link test.
