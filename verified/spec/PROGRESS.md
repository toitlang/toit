# verified/spec progress (Phase 4 requests)

Plan: /home/flo/work/opentoit-sandboxing-reports/07-verified-sandbox-plan.md
(with the 2026-11-10 addendum); requests: format/PHASE4-REQUESTS.md;
spec changes for the other agents: format/SPEC-CHANGELOG.md.

## PROGRESS: verifier memory and robustness (branch spec/verifier-memory)

Brief: R6 (total inference), R8 (memory bounded by the largest method),
no_std readiness, gates. Decisions and results:

* R8 design: `accepts` and the theorem unchanged. `v2/split.rs`:
  `split_ok` checks each method against its own maps plus the global part
  and a few pinned maps of other methods (NON_LOCAL_BRANCH targets, task
  entry offset 1); proven `split_ok ==> accepts(with_maps(g, ms))` and
  `accepts(c) ==> split_ok(gcert_of(c), c.maps)` (so exists-equivalent),
  `theorem_soundness_split`. `check::verify(p, g, oracle, t)` is proven to
  return exactly `pins_sorted(g) && split_ok(vview(p), g@, ms, t)` for the
  maps the oracle yields one method at a time. Zero admits; Verus 738
  verified, 0 errors.
* Representation: program borrowed (`v2/vprog.rs`, `VMethod` = VM's
  `V2Method` layout); global part `XGlobal` (flat block-parameter bits,
  context index, selector representatives trimmed, sorted pins with binary
  search); per-method maps as node lists sharing bottoms (`XMaps`), the
  checker compares successor maps in place (`x_chain_is`).
* Heap: `x_loaded_ok_stream` (Verus) checks objects one at a time as
  vmverify's `from_vm::Objects` converts them; nothing kept.
* Inference: global phase (`infer_global`), then recomputed per method for
  the checker (`Oracle`, no origin tracking). Origins are sparse lists apart
  from the kinds (an 812-byte method made 3 MB of nodes before), per-method
  budgets for nodes and origin words. Total: bounds-checked everywhere;
  `x_wf_program2` first; verified functions only within preconditions.
* Memory (VM, counting allocator): hello world 3619 KB -> 45 KB, sandbox
  tests 3.6-4.5 MB -> 44-56 KB, toit CLI 24.7 MB -> 431 KB. Time about
  +20-25 % (hello 21.7 -> 27.0 ms, CLI 229 -> 272 ms, medians under load;
  one more inference pass). Table in verified/vmverify/README.md.
* R6: reproducers as regression (`vmverify/tests/findings.sh`, in
  `check.sh --tests`); in-process fuzz driver of `toit_vmverify_verify`
  over the saved FFI input (`toit_vmverify_fuzz`, `tests/fuzz_tables.sh`):
  8 x 15 min on the final code: 445,655 mutants, 101,454 accepted, 0 panics, 0 slow calls (and 428,561 on an earlier build). `panic = "unwind"` + `catch_unwind` kept on hosts (the
  inference and conversion are unverified; see README "One Rust library").
* no_std: spec crate builds for riscv32imac/riscv64imac-unknown-none-elf
  without `std`; vmverify for riscv64imac with a copy of the core patched
  (`vmverify/tests/nostd_check.sh`). Blockers, all in verified/core: no
  `#![no_std]`, vstd with `std`, staticlib crate type, not 32-bit clean
  (machine.rs shifts usize by 32; layout.rs 64-bit constants).
* Gates: check.sh --tests passed; ctest 1158/1161 (version, reader,
  udp-reuse-port-test); verify_suite 439/443 accepted (4 compile errors; same set as before plus 5 new tests), system snapshots accepted, differential 439/439 equal, mutation campaign 18,000 mutants (3,744 accepted, 0 stuck).
* Left: contexts' kinds (half of the global part) could share nodes;
  the time overhead of the second inference pass; the core's no_std and
  32-bit work (Phase 5).

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

* Core requests R7, R6 and S1, and the tail-call check (branch
  spec/raise-and-resources; SPEC-CHANGELOG.md has one entry each):
  - R7: raising is an oracle step, `Outcome2::Raise(s, v)` completed by
    `prim::raised` (any trace in a heap extended under the primitive
    contract, or the out-of-memory error); `raise_null` is the reference
    completion (`lemma_raise_null`), which the interpreter runs
    (`exec::x_throw_null`).
  - R6: `prim::resource_throw` (stack overflow or out of memory at
    `grows_stack` opcodes, out of memory at ALLOCATE, the operator
    fallback when a double cannot be allocated); `sound_resource.rs`.
  - S1: the PRIMITIVE protocol (`prim_returns`, `prim_complete`,
    `PrimRet::{Success, Failure, OutOfMemory}`, machine-completed task
    primitives) and `prim_spec` = default contract refined per primitive
    (smi_add, array_at, array_at_put; satisfiable: `sound_prim_spec.rs`).
  - Tail calls: nothing in the spec blocked a verified `replace_frame`
    (the checks match the core's; the missing piece was the stack growth
    before the three opcodes, now a resource point);
    `sound_tail::lemma_replace_frame_slots` gives the slot-by-slot view.
  - `theorem::outcome`/`transition` quantify over the completed oracle
    steps; the theorem also states no completed outcome is `Stuck`.
    Verus 718 verified, 0 errors; the core (328 verified) needed no
    change. The interpreter's byte-content emulation now bounds slice
    nesting (byte-content-depth-test passes).
  - Validation: SOUNDNESS.md, "Tests" (check.sh --tests passed; suite 274
    pass, the previous 273 among them; verify_suite 439/443; system
    snapshots; 11,100 mutants, 0 stuck).
  - For the core: `step::resource_throw`/`exception_like` and the raise
    disjuncts of `advances` can become `theorem::outcome` (completed oracle
    steps); the assumed bridges' contracts should be restated with
    `prim::raised`, `prim::resource_throw` and `prim::prim_returns`.

## Open (not started here)

* The VM's loader still sweeps unreachable code (SOUNDNESS.md, "What the
  VM checks outside the verifier"): drop the sweep when check::verify is
  linked in (VM-linking work).
* VM-BUGS.md 3-5 (message encoder, error encoder, byte content of COW
  arrays and slices): memory-safety bugs in trusted C++ found by the R5
  audit; for an upstream PR.
* The core must follow SPEC-CHANGELOG.md (R5, R1, R4, R7, R6, S1 entries).
* R3 (HASH_FIND, REPEAT): left for the performance pass, as requested.
