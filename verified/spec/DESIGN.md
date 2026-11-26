# Executable specification of the Toit bytecode machine

Phases 0 and 2 of the verified-sandbox plan
(`opentoit-sandboxing-reports/07-verified-sandbox-plan.md`). This crate is
the reference that Phase 3 proves verifier soundness against and that
Phase 4 refines. It specifies two bytecode formats:

* **format 1**, the current 105-opcode bytecode set as implemented by
  `src/interpreter_run.cc` and `src/interpreter_core.cc` (`src/spec_*.rs`,
  `src/exec_step.rs`); it stays until the compiler's default changes, so
  that the differential tests against the C++ VM keep working;
* **format 2**, the revised format of Phase 2 (`src/v2`), which replaces
  it in the verified core. The decisions are in `format/README.md` and one
  note per change in `format/`; the compiler emits it with
  `-Xbytecode_format=2`. Most of this document describes format 1; the
  section "Format 2" at the end summarizes what differs.

## Layout

| File | Mode | Content |
|---|---|---|
| `src/types.rs` | Verus | Abstract state (`Value`, `HeapObj`, `Program`, `State`, `Outcome`, `Stuck`) and its exec mirror with views. |
| `src/bytecodes.rs` | Verus | Opcode numbers and lengths (checked against `src/bytecodes.h` by `tests/opcode_table.rs`). |
| `src/spec_common.rs` | Verus spec | Smis, decoding, stack access, program tables, method headers, dispatch, calls. |
| `src/spec_helpers.rs` | Verus spec | `compare_numbers`, typechecks, `fast_at`, `fast_size`, `hash_do`. |
| `src/spec_step.rs` | Verus spec | `op_*` for every opcode, `unwind`, the intrinsics, and `step(p, s) -> Outcome`. |
| `src/spec_prim.rs` | Verus spec | Completion of PRIMITIVE steps, `task_new`/`task_transfer`, initial state. |
| `src/exec_step.rs` | Verus exec + proof | Verified implementation of 47 opcodes, proven equal to `step`. |
| `src/interp/` | plain Rust | Reference interpreter: loader, unverified mirror of the spec for the remaining opcodes, primitives, emulated system process, scheduler loop. |
| `src/v2/bytecodes.rs` | Verus | Format 2: opcode numbers and lengths (checked against `tools/snapshot.toit` by `tests/opcode_table.rs`). |
| `src/v2/types.rs` | Verus | Format 2: `Program2` (method table), `State2` (frame stack), `Outcome2`; views of the shared exec structs; adapters to the format-1 heap vocabulary. |
| `src/v2/spec.rs` | Verus spec | Format 2: `op_*` for all 101 opcodes, calls, returns, unwinding, raised failures, `step`. |
| `src/v2/prim.rs` | Verus spec | Format 2: primitive completion, task primitives, initial state. |
| `src/v2/exec.rs` | Verus exec + proof | Format 2: verified implementation of 72 opcodes, proven equal to `v2::spec::step`. |
| `src/v2/verifier.rs` | Verus spec | Format 2: the structural verifier (certificate checking). |
| `src/v2/sound*.rs`, `src/v2/theorem.rs` | Verus proof | Format 2: the verifier's soundness proof and theorem (SOUNDNESS.md). |
| `src/interp/` | plain Rust | Reference interpreter for both formats; `exec2.rs` is the unverified mirror of `v2/spec.rs`. |
| `src/bin/toit_spec_run.rs` | plain Rust | CLI: `toit-spec-run [--word-bits 32\|64] [--trace] [--trace-throw] [--trace-bci] [--histogram] [--no-verified] [--stats] [--program-name P] <dump>`. |
| `tests/run_tests.sh` | | Runs `tests/toit/*.toit` on the C++ VM and on the interpreter (format 1: 64-bit, 32-bit, unverified-only; format 2: 64-bit, 32-bit) and diffs. |
| `tests/run_one.sh` | | Same for one file, for debugging. |
| `verified/tools/run_suite.toit` | | Differential test on the repository's whole test suite (both formats). |
| `verified/tools/compare_trace.toit` | | Compares the debug VM's `-Xtrace` with the interpreter's instruction trace. |
| `verified/tools/measure.toit` | | Executed-instruction and code-size comparison of the two formats (on the dumps of `run_suite --format both`). |
| `verified/tools/code_size.toit` | | Code size of the two formats on the system snapshots and ten tests (format note 15). |
| `verified/tools/method_steps.toit` | | Executed instructions per method in both formats (format note 16). |
| `format/` | | The format-2 decisions. |
| `VM-BUGS.md` | | C++ VM findings. |

Commands: `cargo verus verify` (proofs), `cargo build --release`,
`cargo test --release`, `tests/run_tests.sh` (needs `make sdk`),
`toit run verified/tools/run_suite.toit -- --format both` (needs
`make download-packages`),
`toit run verified/tools/compare_trace.toit -- <program>` (needs a debug
build in `build/dbg`, `make BUILD=build/dbg BUILD_TYPE=Debug sdk`).

## Abstract state

* **Program** (`types::Program`, immutable): word size, bytecodes,
  `method_start` (bitmap of method header offsets), dispatch table,
  class bits, class-check ids, interface-check offsets, the 19 operator
  selector offsets, the 9 entry points, the 23 builtin class ids, the 35
  roots (null, true, false, empty array, ..., error strings), literals.
* **State** (`types::State`): `heap: Seq<HeapObj>` (object id = index; no
  addresses, no GC, allocation appends), `globals`, the running task's
  `stack` (bottom first), `try_h`, `bci` (absolute bytecode index), `task`
  (id of the running Task object), `next_task_id`.
* **HeapObj**: class id, `ro` (lives in the read-only program heap), body:
  `Instance(fields)`, `Array`, `Bytes`, `Str`, `Double(bits)`,
  `LargeInt(i64)`, `Oddball`, `Stack(words, try_h)` (suspended task stack).
* A **step** (`spec_step::step`) maps a state to an `Outcome`: `Next(s')`,
  `Stuck(reason)`, `Primitive(s, module, index)` or `Halt(s', kind)`.
  Scheduling between tasks happens only through `task_transfer`.

## Word model

A stack slot, global or field holds a `Value`:

| Value | C++ representation | Created by |
|---|---|---|
| `Smi(i64)` | tagged smi | literals, arithmetic, primitives |
| `Obj(id)` | heap pointer | allocation, literals, roots |
| `RetAddr(bci)` | raw bytecode pointer | calls |
| `FrameMarker` | tagged pointer to the bytecodes | calls |
| `Block(h)` | smi `base - ptr + BLOCK_SALT` | LOAD_BLOCK, LOAD_OUTER_BLOCK, THROW/NLR/NLB |
| `Link(h)` | smi `base - try_sp` | LINK |

* **Word size is a parameter** (`Program.word_bits`, 32 or 64). Smis have
  `word_bits - 1` bits: `smi_min/smi_max` are -2^30..2^30-1 and
  -2^62..2^62-1. Integers outside the range are LargeInteger objects (the
  loader decides per word size). `Smi::from` of an out-of-range value
  wraps (`smi_wrap`), exactly like the C++ VM; this is used for
  LOAD_SMI_U32/LOAD_METHOD. INVOKE_DIV's fast path only applies when the
  quotient is a smi (MIN_SMI / -1 takes the slow path, as in the VM since
  c5d7adec).
* **Block references are stack heights**: `Block(h)` refers to
  `stack[h-1]`; `block_ptr[k]` is `stack[h-1-k]`; THROW's target (`base`)
  is `Block(0)`. The salt disappears.
* **Frame words** (`RetAddr`, `FrameMarker`) may only be pushed by calls
  and consumed by returns, tail calls and unwinding. Every load or store
  that would touch one as a value is stuck (`FrameWord`). This is stricter
  than the C++ VM, which would happily copy a raw bytecode pointer into a
  field (and then hand it to the GC).
* `Block` and `Link` words are smis in the C++ VM; the spec keeps their
  provenance. Operations that would observe them as integers (arithmetic,
  class lookup, Smi::cast for a block slot that holds a Smi, ...) are stuck.

## Stuck states

`Stuck` enumerates the places where the C++ VM performs an unchecked
operation whose result would be undefined (garbage read, out-of-bounds
write, jump into the middle of nowhere). Each is a distinct reason:
`BadInstruction` (bci outside the bytecodes, opcode >= 105, truncated
operands), `StackRange`, `FrameWord`, `BadFrame` (return without frame
marker and return address), `NotSmi`, `NotObject`, `NotInstance`,
`NotArray`, `NotBlock`, `NotLink`, `FieldRange`, `TableRange` (literals,
globals, dispatch, class bits, class checks, interface checks),
`NotMethod` (call target that is not a method header in the method table),
`BadBranch`, `ReadOnly` (write into the program heap, report 01 §3.2),
`NotInstantiable` (ALLOCATE of a non-instance class), `Fatal` (the C++ VM
calls FATAL), `SmiRange` (an encoded smi that the spec refuses to wrap),
`OutOfFuel` (iteration bound of a loop that the C++ VM might run forever on
corrupted collections). The verifier's soundness theorem in Phase 3 is
"accepted programs never reach `Outcome::Stuck`".

## Opcode coverage

All 105 opcodes have spec functions (`spec_step.rs`); `step` dispatches on
every opcode number. The following are **approximations or deliberate
choices**:

1. Stack overflow, preemption and GC are not modeled: CHECK_STACK_OVERFLOW,
   CHECK_PREEMPT, `push_error` on allocation failure and the GC retry loops
   of ALLOCATE/PRIMITIVE are absent; allocation never fails and the stack is
   unbounded. BRANCH_BACK's second operand is therefore unused.
2. IEEE-754 add/sub/mul (INVOKE_ADD/SUB/MUL) use uninterpreted spec functions
   implemented with host `f64`. Numeric comparison has a bit-level specification.
3. Loops bounded by fuel: `hash_find` and `hash_do` (2^32 iterations) and
   nested large arrays in `fast_at` (depth 8). Beyond the bound the spec is
   stuck (`OutOfFuel`) where the C++ VM may loop forever.
4. INVOKE_VIRTUAL_GET/SET field accessors use release-build semantics: the
   field index is read from the accessor's bytecodes without asserting
   their shape (only bounds are checked).
5. Byte arrays are always internal; external byte arrays (resource
   proxies, mapped files) are not modeled.
6. INTRINSIC_HASH_FIND follows the host build (ESP32 builds without IRAM
   helpers bail out immediately).
7. HALT 2 with a non-numeric duration (FATAL in C++) is not distinguished
   from a numeric one.
8. NON_LOCAL_RETURN/NON_LOCAL_BRANCH: the encoded reason smis
   (`arity << 1`, `bci << 1 | 1`) and the new hash-and-position in
   HASH_FIND's NOT_FOUND state must be valid smis (`SmiRange`); the C++
   VM would wrap. UNWIND truncates the reason to 32 bits like the C++ `int`.

## Primitives

The spec treats a primitive as an **oracle** (`spec_prim.rs`): PRIMITIVE
yields `Outcome::Primitive(s, module, index)`; the oracle answers success
(arity, value, new heap) → `prim_success` (return from the method),
failure (error, new heap) → `prim_failure` (continue in the method body
with the error pushed), or missing → `prim_missing`
(`primitive_lookup_failure`). The primitive's own semantics are not
specified in Phase 0. `core.task_new` and `core.task_transfer` change the
machine state (stacks) and are specified (`task_new_step`,
`task_transfer_step`), following `Interpreter::prepare_task` and
`PRIMITIVE(task_transfer)` (which returns through the failure path on the
target stack).

The interpreter dispatches by primitive **name** (from the snapshot's
primitive table), and uses the arity of the method containing the
PRIMITIVE bytecode. Routes per family:

| Family | Route |
|---|---|
| core: arrays, lists, strings, byte arrays, smi/large-int/float arithmetic and comparison, number parsing/printing, json helpers, hashing, finalizer bookkeeping, task plumbing, messaging | Implemented in Rust following `primitive_core.cc` (136 primitives). Finalizers are recorded and never run (no GC). `random` is a fixed LCG. |
| core `encode_error`/`encode_object` | Opaque byte array (the program only passes it on; stack traces of uncaught exceptions are not reproduced). |
| bitmap `blit` | Implemented (in the planned allowed set). |
| math | Implemented with host `f64`. |
| timer, events | Virtual clock (see below). |
| everything else | Unimplemented: the run ends with "unimplemented primitive" (no oracle answer). |

## System process and the outside world (`interp/system.rs`)

The program runs as pid 1; the emulated system process is pid 0 (and the
alias pid -1). `print` goes through service discovery: the core library
opens the service-discovery service (RPC 300 to pid -1, client id 0) and
asks it for the print service (RPC 302, method 0). The emulation answers
the open with a service definition and the discovery with `null` ("no
provider"), so `print` falls back to `StandardPrintService_`, which calls
`core.write_on_stdout`. Replies are delivered as mailbox messages
`[SYSTEM_RPC_REPLY, gid 0, pid 0, reply]` and decoded into fresh heap
objects by `task_receive_message`. Any other RPC to the system process is
answered with an RPC exception "UNIMPLEMENTED".

Scheduler: one process; the step function is per task; tasks switch only
via `task_transfer`. HALT 0 (`__yield__`) resumes immediately if the
mailbox is non-empty; otherwise the virtual monotonic clock advances to the
earliest armed timer and its monitor is posted to the mailbox (this is how
`sleep` and `with-timeout` work); with neither the run ends with
`Deadlock`. `time` returns the virtual clock.

## Loading programs

Route chosen: a **dump tool** rather than a Rust snapshot parser, because
`tools/snapshot.toit` already decodes the whole snapshot.
`tools/spec_dump.toit` (class `SpecDump` in `tools/snapshot.toit`) writes a
line-based text file: bytecodes (hex), the method table
(`m <id> <size> <type> <name>`), all program tables, builtin class ids,
roots, globals, literals, primitive module/primitive names, class names,
and every program-heap object (`o <id> <class> instance|array|bytes|string|double|oddball ...`).
Values are `i<int>` or `o<id>`. The Rust loader (`interp/loader.rs`) turns
integers into smis or read-only LargeInteger objects for the chosen word
size and marks all program-heap objects `ro`. The initial state
(`spec_prim::initial_state`, `Machine::new`) allocates the main task and its
stack and sets up the `__entry__main` frame like
`Interpreter::prepare_process`.

The set of valid method ids comes from the snapshot's **source map** (the
method table). The C++ VM has no such table; see the format notes.

## Spec-to-interpreter relationship and proofs

Theorem (`exec_step::step_verified`, Verus, no `assume`/`admit`):

    requires wf_program(p@), wf_state(old(s)@)
    ensures  r == Some(o) ==> matches(step(p@, old(s)@), o, final(s)@)
             r == None    ==> final(s)@ == old(s)@

i.e. whenever the verified step handles an instruction, the resulting
exec state's view is exactly the spec successor (or the same stuck reason).
Proven for **47 opcodes**: LOAD_LOCAL, LOAD_LOCAL_WIDE, LOAD_LOCAL_0..5,
POP_LOAD_LOCAL, STORE_LOCAL, STORE_LOCAL_POP, LOAD_LITERAL(_WIDE),
LOAD_NULL, LOAD_SMI_0, LOAD_SMIS_0, LOAD_SMI_1, LOAD_SMI_U8/U16/U32,
LOAD_METHOD, POP, POP_1, the 8 BRANCH opcodes, INVOKE_EQ/LT/GT/LTE/GTE,
INVOKE_BIT_OR/XOR/AND/SHL/SHR/USHR, INVOKE_ADD/SUB/MUL/DIV/MOD — including
the double fast paths, the virtual-call fallback (method lookup through
the dispatch table, `lookup_failure`, call frame) — plus the
`BadInstruction` stuck state. `step` is opaque; per-family lemmas reveal
it. Check time: about 5 s for the crate (`cargo verus verify`, vstd
cached; 224 verified items).

Trusted base of the proof: the three `external_body` functions for
IEEE-754 arithmetic; the loader establishing
`wf_program` (also asserted at run time in `Machine::new`); Rust/Verus.
The checker of shipped certificates and the heap check (the code devices
run) also rely on `xvec.rs`: element access without the bounds check
(`ix`, `ix_ref`, `vix`, `vput`, `subslice`: the index is a precondition
Verus proves at every call site) and fallible growth (`try_push`,
`try_with_capacity`, `try_copy`, `try_filled`: `Err(Oom)` instead of an
abort), each a few lines with the contract of the vstd operation it
replaces, so that the device library has no panic path
(verified/vmverify/README.md, "No panics on devices").

**Open obligations** (spec written, interpreter mirrors it, not yet
proven): the other 58 opcodes — LOAD_OUTER, STORE_OUTER, the field
opcodes, globals (incl. lazy and dynamic), LOAD_BLOCK, LOAD_OUTER_BLOCK,
ALLOCATE, IS/AS checks, AS_LOCAL, all INVOKE_STATIC/BLOCK/LAMBDA/
INITIALIZER/VIRTUAL forms, INVOKE_AT/AT_PUT/SIZE (fast_at/fast_size),
PRIMITIVE, THROW, RETURN(_NULL), NON_LOCAL_RETURN(_WIDE), NON_LOCAL_BRANCH,
IDENTICAL, LINK, UNLINK, UNWIND, HALT, the four intrinsics — and the
primitive completion functions, `task_new_step`, `task_transfer_step`,
`initial_state`. Their exec mirrors are in `interp/exec.rs` and
`interp/intrinsics.rs`, written to follow the spec function by function;
`tests/run_tests.sh` checks that the unverified mirror alone produces the
same results as the verified mix.

## Testing

### Validation at scale (Phase 2)

`verified/tools/run_suite.toit` discovers every `tests/*-test.toit`,
`tests/regress/*-test.toit`, `-test-slow` and `-test-force` program (418),
compiles it, dumps it, runs it on the interpreter, and when the
interpreter does not stop at an unimplemented primitive or a system
service the emulation does not provide, compares stdout and exit code with
the C++ VM (run like ctest: from the repository root, arguments `foo bar
gee`). Each runnable test runs with 64-bit and 32-bit smis and with the
verified step disabled; a test whose VM output differs between two VM
runs is classified as nondeterministic. Result (format 1): 269 runnable,
269 pass; 133 not runnable (unimplemented primitives or system services:
22 network, 16 other system RPCs, 7 spawn, ...); 10 exceed the 50 M step
limit (with 3 G steps 4 of them pass, 2 stop at an unimplemented
primitive, and 4 do not finish: `finalizer-test` waits for a GC, and the
spec models neither GC nor stack overflow); 2 nondeterministic (`block-test`
prints identity hashes, `rpc-test`); 4 `-force` tests do not compile
without `--force`. Discrepancies found and fixed: all in the
interpreter's primitives and world (raw32-to-float range, copy-on-write
byte arrays in MutableBlob arguments, the timer event state,
process-send to the own process, the program name, the timing of system
replies, service discovery of services the host system provides), plus
the spec following the VM fixes of c5d7adec. No VM bug (see `VM-BUGS.md`).

`verified/tools/compare_trace.toit` runs a program on the debug VM with
`-Xtrace` (on one scheduler thread) and on the interpreter with
`--trace-bci`, and
compares bci and opcode of every instruction of the program's process,
skipping the system process's instructions in between (the VM prints a
marker whenever a process leaves the interpreter, including on
preemption; the program must resume where the interpreter continues, and
any other mismatch is a divergence). It stops at the first
branch on a primitive result that depends on the outside world
(`task_has_messages` when the first system reply arrives).

Measured 2026-11-11 (debug build of `sandbox-integration` plus the fixes
of `fixes/trace-and-debug`), steps compared up to that stop, no
divergence:

| Program (`tests/trace/`) | Format 1 (C++ interpreter) | Format 2 (core, checked loop) |
|---|---|---|
| `sort.toit` | 1,037,023 | 1,147,644 |
| `control.toit` | 220,249 | 397,559 |
| `maps.toit` | 159,856 | 467,701 |
| `numbers.toit` | 22,764 | 40,721 |
| total | 1,439,892 | 2,053,625 |

The earlier figure (1,450,092, same numbers except `control.toit` with
230,449) predates two changes. The hardened interpreter's hash-find
intrinsic had stopped matching: it rejected the smi 0 of a free index slot
as "null" and fell back to the Toit code at every insertion and miss (VM
bug, fixed; `maps.toit` diverged in `rebuild-index_`, which the old
switch-point heuristic misreported 28 steps later at step 563). And
`control.toit`'s catch block used `it`, so it was a one-parameter block
and every `catch` raised CODE_INVOCATION_FAILED instead of running
`protected`; it now runs the intended throws and finally blocks.

Format 2 (`--format 2`): the program runs on the verified core's checked
run loop (no `-Xverify`), which prints `[<bci>] #<opcode>` per instruction
under `-Xtrace` (the hook is `toit_v2_tracing`/`TOIT_V2_REPORT_TRACE`, see
`src/interpreter_v2.h`; the core's half, a report per instruction in
`run_checked`, is not in the core yet and the figures were measured with
it applied), against `exec2.rs`. Two known differences are
outside the spec's model: the core runs an instruction again after
growing the stack (the tool skips the repeated line, 2-4 per program),
and an exception the core raises (a failure, not a `throw`) carries an
encoded stack trace where the spec's is null (format note 5,
`format/PHASE4-REQUESTS.md` R2), so code that tests the trace of a caught
failure (`catch`'s `if stack`) branches differently; the old
`control.toit` diverged there. Format 2 executes more instructions on
`maps.toit` because it has no hash-find instruction (R3).

### Spec test programs

`tests/run_tests.sh` compiles each `tests/toit/*.toit` with this tree's
compiler, runs it on the C++ VM, dumps it, runs the interpreter with 64-bit
and 32-bit smis and with the verified step disabled, and diffs stdout plus
exit code. 14 programs: hello, collections, strings, blocks, non_local,
try_finally, exceptions, large_ints, floats, tasks (monitors, channels,
mutex, semaphore, Task.group), sleep_timers, maps, classes, smi_edges. All
pass, in both formats. The host VM is 64-bit only; `smi_edges.expected32`
holds the hand-checked 32-bit expectation for the one line that
legitimately differs. About 55-60% of executed steps run through the
verified code in format 1, 85-92% in format 2.

## Findings in the current VM

Both were fixed in the VM (commit c5d7adec) and the spec follows:

* **INVOKE_DIV with MIN_SMI / -1** computed `Smi::from(MIN_SMI / -1)`,
  which wrapped back to MIN_SMI on 64-bit.
* **INTRINSIC_HASH_FIND, REBUILD state** read `OLD_SIZE` after the first
  push, so the rebuild block received the state slot instead of the old
  size.

Phase 2 validation (see `VM-BUGS.md` and "Validation at scale" below) found
no further VM bugs; all discrepancies were in the reference interpreter's
primitives and world emulation.

## Places where the current bytecode format made the spec awkward

Input to the Phase 2 format revision; each item is resolved in format 2
(note numbers refer to `format/`): 1 -> notes 1 and 12; 2 -> note 3; 3 ->
notes 2 and 6; 4 -> note 4; 5 -> note 5; 6 -> note 1 (accessor field in
the header); 7 -> note 11; 8 -> note 5 (a tree-shaken operator is a
lookup failure); 9 -> note 2 (primitive success is a frame return) and
`v2::prim` (task state with frames); 10 -> note 14 (table check); 11 ->
note 13; 12 -> note 7 (checked stores, STORE_FIELD_THIS checks read-only
objects); 13 -> note 12.

1. **Method ids are byte offsets.** Validity of a call target cannot be
   decided from the bytecodes; the spec needs the method table from the
   source map. Method ids travel as plain smis through the heap
   (Lambda_ field 0, LazyInitializer_ field 0, LOAD_METHOD results in stack
   slots), so any smi can be presented as a method id.
2. **Block references are salted smis** on the value stack. The spec has
   to invent a provenance tag (`Block`) and still cannot exclude stale
   references to reused slots; LOAD_OUTER/STORE_OUTER/LOAD_OUTER_BLOCK
   index backwards from an arbitrary height.
3. **Frames are implicit.** Return address and frame marker live on the
   value stack; RETURN, tail calls and intrinsics carry or assume the frame
   height and arity, so every one of them must re-check the frame words.
   INVOKE_LAMBDA_TAIL and the intrinsics address parameters at fixed
   offsets past the frame words.
4. **try/finally** pushes four words of mixed meaning (result, target,
   reason, chain); the unwinder relies on the exact shape
   `[link words][block ref][frame]` at `try_h + 3`; the reason slot is also
   the Toit local `is-exception` (the program can overwrite it) and is
   truncated to a 32-bit `int`. Unwind reasons overload smis (-1, -2,
   `arity << 1`, `bci << 1 | 1`).
5. **Failure entry points** (lookup, as-check, code, program, primitive
   lookup) are called with extra words pushed and must never return.
6. **Field-accessor inlining** in INVOKE_VIRTUAL_GET/SET decodes the
   target method's bytecodes at run time.
7. **Intrinsics are re-entrant state machines** whose state lives in stack
   slots at fixed offsets; INTRINSIC_HASH_FIND is the largest single piece
   of the spec (about 250 lines) and hid a bug. INVOKE_SIZE falls through to
   INVOKE_VIRTUAL_GET.
8. **Operators** have a fast path plus a virtual fallback through
   `invoke_bytecode_offsets`, which may be -1 when tree-shaken.
9. **PRIMITIVE's arity** comes from the VM's table, not from the
   bytecode, and success returns from the enclosing method (pops the
   caller's frame). `task_transfer` "fails" on purpose to continue on
   another stack; a new task's stack is a fake call at bci 1 of
   `__entry__task`.
10. **Dispatch** reads `dispatch_table[class_id + selector]` with no bound;
    the selector check is against the target's header.
11. **Silent truncations and wraps**: `Smi::from` overflow (DIV,
    LOAD_SMI_U32 on 32-bit), `int` casts of smis (UNWIND,
    LOAD/STORE_GLOBAL_VAR_DYNAMIC, HASH_DO step).
12. **Program-heap objects are writable** by STORE_FIELD and the at_put
    paths; the spec makes such writes stuck.
13. **Lambda captures** are either an Array or a single value in field 1,
    distinguished by type at run time.

## Format 2

`src/v2` specifies the revised format (decisions in `format/`). The state
adds a frame stack (`Frame { method, ret, base, handler }`, `handler`: a
try block called by TRY) to the object stack, which holds only values
(`Smi`, `Obj`, `BlockRef(frame, slot)`, and the two words of an unwinding
token, `Token`, in a finally code's slots, format note 23); a suspended
task is a `Body::Stack2` (object stack, frames, bci).
The program has a method table (`MethodInfo`) decoded by the trusted
loader from the method headers; every instruction fetch is checked
against the current frame's method.

Shared with format 1: values, heap objects and the heap vocabulary
(typechecks, `compare_numbers`, `fast_at`, `fast_size`, smi arithmetic),
reached through the adapters `as1`/`p1`; the primitives of the
interpreter. The interpreter's `Machine` runs either format (`format`);
`ExecState` and `ExecProgram` carry the format-2 fields (`frames`,
`methods`), which the format-1 views ignore.

Proofs: `v2::exec::step_verified` is proven equal to `v2::spec::step` for
72 opcodes (zero `assume`/`admit`): LOAD_LOCAL (all forms), POP_LOAD_LOCAL,
STORE_LOCAL(_POP), the constants (LOAD_LITERAL(_WIDE), LOAD_NULL,
LOAD_SMI_0/1/U8/U16/U32, LOAD_SMIS_0, LOAD_METHOD), POP, POP_1, the eight
branches, the sixteen arithmetic and comparison operators with their
fallback (lookup, arity check, call, raised LOOKUP_FAILED), INVOKE_STATIC
(with the receiver check), INVOKE_STATIC_TAIL, INVOKE_VIRTUAL(_WIDE),
RETURN, RETURN_NULL, THROW, LOAD_BLOCK, LOAD_OUTER, STORE_OUTER,
LOAD_OUTER_BLOCK, INVOKE_BLOCK, NON_LOCAL_RETURN, NON_LOCAL_BRANCH, TRY,
UNWIND (with the unwinding loop, entry into finally code and the raised
exceptions), LOAD_FIELD(_WIDE), LOAD_FIELD_LOCAL, POP_LOAD_FIELD_LOCAL,
STORE_FIELD(_WIDE,_POP), LOAD_FIELD_THIS, STORE_FIELD_THIS, and the
invalid instruction. Open (spec written, `interp/exec2.rs` mirrors it):
globals, ALLOCATE, IS/AS, INVOKE_LAMBDA_TAIL, INVOKE_INITIALIZER_TAIL,
INVOKE_VIRTUAL_GET/SET, INVOKE_AT/AT_PUT/SIZE, IDENTICAL, PRIMITIVE, HALT,
and the primitive and task completions. 85 % of the format-2 instructions
executed by the test suite run through verified code.

The structural verifier is specified in `v2/verifier.rs` as a checker of
a certificate (stack maps of slot kinds, block-parameter masks, block
contexts) with per-instruction rules, method and table checks, the
invariant and the soundness theorem in `v2/theorem.rs`, proven in Phase 3
without admits (see SOUNDNESS.md). The
interpreter's loader runs three of its table checks on every format-2
program (receiver ranges against the dispatch table, fields of
LOAD_FIELD_THIS/STORE_FIELD_THIS, terminators); they hold for all test
programs.

Validation: all 14 spec test programs and all 268 runnable suite tests
produce the C++ VM's (format-1) output when compiled to format 2 and run
on the interpreter (64-bit and 32-bit smis; verified and unverified
step agree).
