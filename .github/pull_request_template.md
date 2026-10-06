## What and why

<!-- What this changes, and why it is needed. Link the issue it addresses. -->

## Tests

- [ ] `Tools/test-all.sh` passes (paste the last lines below)
- [ ] `Tools/local-gate.sh <branch>` passes, if the change touches the app or anything it links
- [ ] New behavior has a test; a fix has a test that fails without it

```text

```

## Decisions

- [ ] No new decision, or an ADR is added in `docs/decisions/`

## Privacy impact

<!-- Does anything new leave the phone, or reach a prompt? If so: what, to whom, under which topic, and what the consent sheet shows. Write "None" if nothing changes. -->

- [ ] Peers still send typed values only, and no peer text reaches a prompt
- [ ] Every send goes through `Outbox`, and every receive through `Inbox`

## Device steps

<!-- Only if the behavior can be seen only on a device. Numbered and specific, for example:
1. Phone A: tap Add friend. Expect: a code within 2 seconds. -->
