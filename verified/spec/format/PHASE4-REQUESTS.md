# Spec change requests from Phase 4 (verified core)

Requests from the implementation of the core (verified/core). None of them
is applied: verified/spec/src/v2 is owned by the spec work. Each lists the
problem the core hit, the request and what the core does meanwhile.

## R1. Unwinding without a heap token (note 4)

Problem: entering finally code with a pending unwinding allocates a
5-word token. A non-local `return` out of a monitor method (the compiler
wraps monitor bodies in a try/finally) therefore allocates on every call:
tests/channel-retention-test.toit (Channel.receive must not allocate)
fails in format 2. Under heap exhaustion the token allocation can fail,
and the exception then skips the finally code;
`services-resource-close-pressure-test` (format 2) ends with exit code 1
right after the first out-of-memory, which fits this, but the cause is
not confirmed.

Request: keep the pending unwinding's non-reference data (kind, frame,
bci, height) in the handler's frame record and the reference (exception
or return value) in the first slot of the finally code; the token slot
holds a smi naming the record. UNWIND checks that the record belongs to
the current frame and matches the token, so the program still cannot
forge an unwinding. A `break` out of finally code leaves a stale record,
which the next TRY in that frame overwrites and a return discards (one
record per frame suffices, since TRY always opens a new frame). No
allocation, no out-of-memory path.

Meanwhile: the core follows the spec and allocates; on allocation failure
it throws `OUT_OF_MEMORY` from the handler's frame (the finally code does
not run).

Applied 2026-11-10 with a change (format note 17, SPEC-CHANGELOG.md): one
record per frame is unsound when finally code contains a try/finally
itself, so the records form a stack next to the handlers (the record
takes the entered handler's place, so still no allocation); the token is
the record's index; UNWIND checks frame and token slot; TRY drops the
frame's stale records, which bounds them by the frame's height.

## R2. Stack trace and message of raised failures (note 5)

Problem: the spec's raised exception has a null trace, so failure output
lost the details format 1 prints ("an A is not a B", the selector of a
failed lookup, the block arity). 45 negative tests compare that output.

Request: none for the spec's semantics; record in note 5 that the VM
encodes the trace and the format-1 message (as `encode-error_` does) when
it raises. The core passes the message words (receiver, selector offset,
class id, bci of the check, arities) to the C++ allocation of the
exception; the trace is outside the spec's model.

## R3. HASH_FIND and REPEAT (note 16)

Not decided here. The benchmarks spend their time in dispatch and
run-time checks (DESIGN.md, "Measurements"), not in loops a REPEAT
instruction would shorten; format 1's `SmallInteger.repeat` intrinsic is
visible in profiles (tests/profiler differ in attribution). Left for the
performance pass.

## R4. Loader obligations and the heap check

`loaded_ok` (SOUNDNESS.md) has a heap part that only the unverified
heap_check.rs checks. Request: a verified executable check of the heap
part, so that the VM can run it on untrusted launches next to
`check::verify`.

Applied 2026-11-10: `v2::heap_check::x_loaded_ok` (proven equal to
`loaded_ok`) and `x_loaded_heap_ok` (the heap part).

## R5. The fields of a task the VM owns

Problem (found by verified/core/fuzz): a mutant of tests/class-id-test.toit
that `check::verify` accepts changes `STORE_FIELD_THIS 9` to
`STORE_FIELD_THIS 0` in `Task_.initialize-entry-task_`. Field 0 of a task
is the task's `Stack` (`Task::STACK_INDEX`) and field 1 its id; the VM
reads them (scheduler, task switch, GC). The spec treats them as ordinary
fields of the instance (the class' field count includes them), so the
program may overwrite the stack reference and the VM then uses an
arbitrary value as a stack.

Request: model a task's first two fields as not accessible (or as
read-only for the id) in `spec::step` and in the verifier's receiver-range
check, for example by giving the `Task_` class a field base of 2.

Applied 2026-11-10 (SPEC-CHANGELOG.md): `spec::field_readable` /
`field_writable`, the verifier's `this_load_ok` / `this_store_ok` and
`task_class_ok`, and `machine_objects_ok` in the theorem. The spec now
matches what the core does.

Meanwhile: the core refuses to read or write field 0 of a task and to
write field 1 (LOAD_FIELD/STORE_FIELD raise INVALID_PROGRAM, the `this`
variants stop the process with a stuck state). The format-1 interpreter
has the same hole for unverified programs; not changed here.

## R6. The inference must not panic on malformed programs (vm/verifier-link): done

Problem (found by the launch-time fuzz mode of verified/core/fuzz, header
mutations; reproducers in verified/core/fuzz/findings/infer-panic-*):
`v2::infer::infer` indexes out of bounds on programs that `x_wf_program2`
accepts:

- infer.rs:130, `origins[0] = ...` for a method with an empty body
  (`size == 0`): infer-panic-empty-body.snapshot.
- infer.rs:187, `p.methods[t]` for an INVOKE_STATIC whose dispatch entry
  is not a method index (the dispatch table is only checked later, by
  `x_tables_ok`): infer-panic-dispatch-target.snapshot.

The VM runs the inference on untrusted input at every untrusted launch.
verified/vmverify catches the panic (`panic = "unwind"`, `catch_unwind`)
and rejects the program, so this is not a soundness problem, but with
`panic = "abort"` (the core's profile, and likely on devices) it would let
any untrusted program abort the whole VM.

Request: make `infer` total on every program `x_wf_program2` accepts (no
indexing without a bounds check; reject instead). A fuzz target that runs
`infer` + `check::verify` on mutated method tables would keep it so.

Meanwhile: vmverify checks `x_wf_program2` before the inference, catches
panics and rejects (`INTERNAL`, "verifier failure").

Status (spec/verifier-memory, 2026-11-10): `infer.rs` was rewritten for R8
and is total: it checks `x_wf_program2` itself, never indexes without a
bounds check or an established bound, uses checked arithmetic on offsets
from the bytecodes, and calls the verified functions only within their
preconditions (`post_pre`, `pins_sorted`, `depth >= 1`, ...); any
malformed input ends in an error (and a rejection), and per-method memory
budgets stop runaway allocation. Regression: `verified/vmverify/tests/
findings.sh` (in `check.sh --tests`) runs `toit.run --verify` on every
reproducer of verified/core/fuzz/findings: no panic, `infer-panic-*` and
`r5-*` rejected. Fuzzing of the launch-time entry point in-process:
`toit_vmverify_fuzz` (`tests/fuzz_tables.sh`) mutates copies of the exact
FFI input the VM hands `toit_vmverify_verify` (tables, image, globals,
primitive table; saved with `toit.run --emit-canonical=X.tables`); see
verified/vmverify/README.md for the 15-minute run. vmverify keeps
`panic = "unwind"` and `catch_unwind` on hosts (defense in depth: the
inference and the conversion are unverified Rust whose panic freedom is
argued and fuzzed, not proven); the `no_std` build for devices has no
unwinding, so there a panic would abort, which is why the inference must
be total.

## R7. The heap check and `loaded_ok`'s object bound (vm/verifier-link): done

Resolved by the verified `heap_check::x_loaded_ok` (merged with
sandbox-integration 724e9fc0): vmverify now accepts only if
`check::verify` and `x_loaded_ok` both accept. The original request:

`heap_check::check_heap` does not check `heap0.len() < 2^29`, which
`loaded_ok` requires. vmverify checks it in its verdict glue
(verified/vmverify/src/verify.rs). Request: include it in the verified
heap check that replaces heap_check.rs (R4), so that the glue only calls
proven code. vmverify builds the heap from VM memory with the same
`Loaded` type, so a verified check with the signature
`check_heap(&Loaded) -> Result<(), String>` (or a bool) drops in.

## R8. Certificate memory (vm/verifier-link): done

Problem: the VM now verifies at every untrusted launch, and Phase 5 must
verify on the device at install time. `XCert::maps` holds one
`Option<Vec<XKind>>` (24 bytes) per byte of every method body plus a
vector of kinds at every reachable instruction start, for the whole
program at once. Measured high-water marks of the verification
(verified/vmverify/README.md, "Cost"): 3.6 MB for a 25 KB hello world,
24 MB for the toit CLI (323 KB of bytecodes), i.e. 75 to 150 bytes per
bytecode byte. The inference takes 85 to 90 % of the time.

Request: a certificate representation that is linear in the number of
instruction starts rather than bytes (a sparse map, or offsets sorted per
method), with interned or shared kind vectors (consecutive maps mostly
differ in the top slots). Keeping `accepts` unchanged and only changing
`XCert` and its view should leave the proof's statement intact.

Status (spec/verifier-memory, 2026-11-10): done, with `accepts` and the
theorem unchanged and zero admits. The verifier no longer holds a whole
certificate:

* `v2/split.rs`: `split_ok(p, g, ms, t)` checks each method against its
  own maps and the global part `g` (with `pins`, the few maps other
  methods look up: NON_LOCAL_BRANCH targets and the task entry's offset
  1). Proven: `split_ok ==> accepts(with_maps(g, ms))` and every accepted
  certificate splits (`exists c. accepts` iff `exists g, ms. split_ok`);
  `theorem_soundness_split`.
* `check::verify(p, g, oracle, t)` returns exactly `pins_sorted(g) &&
  split_ok(vview(p), g@, ms, t)` for the maps `ms` the oracle yields one
  method at a time; maps are lists of kinds sharing their bottoms
  (`XMaps`), dropped after their method.
* The program is borrowed (`v2/vprog.rs`, `VProgram`); vmverify no longer
  copies the VM's tables, and the heap is checked one object at a time
  (`x_loaded_ok_stream`).
* The inference computes the global part first (`infer_global`, maps
  dropped per method) and recomputes each method's maps for the checker
  (`infer::Oracle`).

Peak memory and time: verified/vmverify/README.md, "Cost" (hello world
3.6 MB -> about 46 KB, the toit CLI 24.7 MB -> about 0.43 MB).
