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

* Validation (2026-11-10, after the last spec change): verified/check.sh
  --tests: Verus core 128 / spec 690 verified, 0 errors; escape-hatch
  audit passed; layout check passed; spec differential tests 15/15;
  sandbox ctests 90/91, the failure (tests/sandbox/field-access-test)
  is pre-existing: it fails identically on sandbox-integration's src/
  (no file outside verified/ changed on this branch). run_suite.py
  --format 2: 273 pass (all 268 of the previous run among them), 135
  unimplemented, 8 step limit, 2 nondeterministic, 4 compile errors, 1
  primitive-oracle difference (events-primitive-group-test).
  verify_suite: 434/438 accepted (4 do not compile); system snapshots
  accepted; mutation campaign 12,300 mutants, 2,450 accepted, 0 stuck.

## Open (not started here)

* The VM's loader still sweeps unreachable code (SOUNDNESS.md, "What the
  VM checks outside the verifier"): drop the sweep when check::verify is
  linked in (VM-linking work).
* VM-BUGS.md 3-5 (message encoder, error encoder, byte content of COW
  arrays and slices): memory-safety bugs in trusted C++ found by the R5
  audit; for an upstream PR.
* The core must follow SPEC-CHANGELOG.md (R5, R1, R4 entries).
* R3 (HASH_FIND, REPEAT): left for the performance pass, as requested.
