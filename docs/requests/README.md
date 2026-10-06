# Interface change requests

These files are the development record of how shared interfaces changed: each is one lane's requests to the Orchestrator, with the answers. The terms are defined in the [PROCESS.md glossary](../PROCESS.md#glossary).

During development, lanes did not edit `Packages/StarlingCore/` or files they did not own. To ask for a change, a lane added `docs/requests/<lane>.md` (for example `F.md`) on its branch with:

1. What it needed changed, as a concrete Swift signature where possible.
2. Why, with the test or scenario that showed the need.
3. What it did meanwhile (a local workaround, or BLOCKED).

The Orchestrator answered in the same file, made accepted changes on its own branch, and merged them to `main`; lanes then rebased. Code comments cite these files as, for example, "P15-E request 4.1" (item 4.1 in `P15-E.md`).

New contributors propose interface changes in an issue instead; see [CONTRIBUTING.md](../../CONTRIBUTING.md#interfaces-and-decisions).
