# Phase 1 G device checklist

Run after H wires the real policy, consent provider, and Outbox audit observer, and F supplies PSI context on each send. Use synthetic inputs. No iPhone was connected during G's implementation; these checks are pending owner execution. Phone B may be the paired Mac test peer if it supports the same flow.

1. Phone A: set Activity to Never, then try sending an activity query to paired Phone B. Expect: policy denial, no consent sheet, no received activity on B, and no success audit entry on A.
2. Phone A: set Activity to Ask Each Time and send the synthetic value "boba". Expect: the sheet lists Activity and "boba", identifies the recipient, and says model location is self-declared and unverified. Leave the sheet open. Expect: no activity message on B. Decline. Expect: no received message or success audit entry.
3. Phone A: repeat step 2 and approve. Expect: one message on B and one local success summary on A. Send again. Expect: a new consent request, with no reuse of the earlier approval.
4. Phone B or Mac peer: declare a third-party cloud model. Phone A: enable Only Negotiate with On-Device Agents and attempt a query. Expect: denied before consent. Clear the cached card and repeat. Expect: denied until a suitable card is received; hello remains available to exchange cards.
5. Phone A: allow sharing Activity with on-device peers and start matching using the insecure PSI stub. Expect: consent lists the full typed input set and warns that the provider is not private. Decline. Expect: no PSI step reaches B. Set Activity to Never and retry. Expect: denied before consent.
6. Phone A: inspect and clear the local audit log after an approved exchange. Expect: message type and issue/value-kind summaries, with no raw activities, amounts, time windows, flags, or PSI bytes. Disconnect B and attempt another send. Expect: a send failure creates no success record. Clear the log. Expect: empty local history.

7. Phone A: choose Maybe and proceed to an acceptance with paired Phone B. Expect: the consent row Your interest says `You said "maybe".`. Repeat with Down. Expect: `You said "down".`. Set the Down level disclosure rule to Never and retry. Expect: denial before sending that acceptance.
8. Phone A: leave an Ask Each Time consent sheet open, then cancel the negotiation. Expect: the pending send produces no message on B and no success audit entry, even if the consent callback completes afterward.
