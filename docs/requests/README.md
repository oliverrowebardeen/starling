# Interface change requests

Lanes never edit `Packages/StarlingCore/` or files they do not own. To ask for a change, add `docs/requests/<lane>.md` (for example `F.md`) on your lane branch with:

1. What you need changed, as a concrete Swift signature if possible.
2. Why, with the test or scenario that shows the need.
3. What you are doing meanwhile (a local workaround, or BLOCKED).

The Orchestrator answers in the same file, makes accepted changes on its own branch, and merges them to `main`; lanes then rebase.
