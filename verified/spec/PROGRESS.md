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

* R5 audit: table "Machine-interpreted objects" in SOUNDNESS.md. No
  further spec gap; three memory-safety gaps in trusted C++ consumers of
  program-writable collection fields (message encoder, error encoder,
  byte content of COW arrays/slices), recorded as VM-BUGS.md 3-5 for an
  upstream PR (src/ is not edited here).

* R1 (unwinding without a heap token): finally records (format note 17),
  spec, prim, verifier (UNWIND value slot), exec step, reference
  interpreter, invariant (`fin_ok`, `fins_ok`) and all proofs. Verus: 684
  verified, 0 errors. New test tests/toit/finally_records.toit (nested
  try/finally in finally code, break out of finally, value slot) passes
  against the C++ VM; 433/437 suite programs and the system snapshots
  accepted; run_tests.sh 15/15.

* R4: `v2::heap_check::x_loaded_ok` / `x_loaded_heap_ok` (Verus, proven
  equal to `loaded_ok` / `loaded_heap_ok`); `toit_spec_verify`'s verdict
  is `verify && x_loaded_ok`. Verus: 690 verified, 0 errors; 434/438 suite
  programs and the system snapshots accepted.

* Loader vs verifier on unreachable code: the verifier is right (the
  machine decodes only mapped offsets); SOUNDNESS.md lists what the VM
  must still do outside the verifier (decode the tables, run verify and
  x_loaded_ok, memory bound, primitive contract). R2 recorded in note 5.

## In progress

* Validation.

## Next

1. Full validation (check.sh --tests, run_suite.py format 2, verify_suite,
   system snapshots, mutation campaign) and SOUNDNESS.md numbers; R2 note.
