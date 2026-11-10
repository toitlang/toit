# verified/spec progress (Phase 4 requests)

Plan: /home/flo/work/opentoit-sandboxing-reports/07-verified-sandbox-plan.md
(with the 2026-11-10 addendum); requests: format/PHASE4-REQUESTS.md;
spec changes for the other agents: format/SPEC-CHANGELOG.md.

## Done

* R5 (task fields the VM owns): spec, verifier, exec step, reference
  interpreter, heap check, invariant (`running_ok`, `task_obj_ok`) and
  theorem (`machine_objects_ok`). Verus: 667 verified, 0 errors. The fuzz
  finding `task-stack-field-store.snapshot` is now rejected; 433 of 437
  suite programs (4 do not compile) and the three system snapshots are
  still accepted; tests/run_tests.sh 14/14.

## In progress

* R5 audit table in SOUNDNESS.md.

## Next

1. R1: unwinding without a heap token.
2. R4: verified executable heap check (`loaded_ok_heap`).
3. Loader/verifier agreement on unreachable code.
4. Full validation (check.sh --tests, run_suite.py format 2, verify_suite,
   system snapshots, mutation campaign) and SOUNDNESS.md numbers; R2 note.
