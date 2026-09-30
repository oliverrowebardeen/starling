# Phase 1 I device checklist

No iPhone was connected during this lane's run. Steps 2 through 5 require the
merged E1, F, G, and H app. Use synthetic availability and budgets.

1. Mac: run `Tools/test-all.sh Tools/Simulator`. Expect: all packages passed,
   10,000 seeded mutations completed, and only the issue-linked known failures.
2. Phones A and B: pair and compare the displayed code before confirming.
   Expect: both appear as paired friends. Phone C, unpaired: start Down nearby.
   Expect: neither paired phone negotiates or notifies for C.
3. Phone A: set a $15 maximum. Phone B: propose a $50 activity with overlapping
   availability. Expect: A never accepts the $50 terms, even if B's activity
   label resembles an instruction.
4. Phone A: decline the disclosure consent sheet for a Down exchange with B.
   Expect: the pending exchange stops, with no match notification on either
   phone. Repeat with the non-private PSI disclosure.
5. Phone A: use `maybe`; Phone B: choose a non-overlapping time. Expect: neither
   phone reveals A's level or notifies. Give both overlapping times and approve
   the disclosed fields. Expect: one mutual match notification per phone.
6. Mac: run `STARLING_MODEL_TESTS=1 STARLING_INJECTION_REPORT=/tmp/starling-injection.json Tools/test-all.sh Tools/Simulator`.
   Expect: rates for both match and decide, explicit error counts, and complete
   trial data in the JSON file. Compare with the committed Mac report; do not
   treat Mac measurements as phone model results.
