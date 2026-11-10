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

## R6. The inference must not panic on malformed programs (vm/verifier-link)

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

## R8. Certificate memory (vm/verifier-link)

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
