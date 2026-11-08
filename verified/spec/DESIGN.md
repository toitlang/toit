# Executable specification of the Toit bytecode machine

Phase 0, part 2 of the verified-sandbox plan
(`opentoit-sandboxing-reports/07-verified-sandbox-plan.md`). This crate is
the reference that Phase 3 proves verifier soundness against and that
Phase 4 refines. It specifies the *current* 105-opcode bytecode set as
implemented by `src/interpreter_run.cc` and `src/interpreter_core.cc`.

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
| `src/bin/toit_spec_run.rs` | plain Rust | CLI: `toit-spec-run [--word-bits 32\|64] [--trace] [--no-verified] [--stats] <dump>`. |
| `tests/run_tests.sh` | | Runs `tests/toit/*.toit` on the C++ VM and on the interpreter (64-bit, 32-bit, unverified-only) and diffs. |
| `tests/run_one.sh` | | Same for one file, for debugging. |

Commands: `cargo verus verify` (proofs), `cargo build --release`,
`cargo test --release`, `tests/run_tests.sh` (needs `make sdk`).

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
  LOAD_SMI_U32/LOAD_METHOD and INVOKE_DIV.
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
2. IEEE-754 add/sub/mul (INVOKE_ADD/SUB/MUL) and the int/double branch of
   `compare_numbers` are uninterpreted spec functions (`double_add`, ...,
   `compare_mixed`); the interpreter implements them with host `f64`.
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

Trusted base of the proof: the four `external_body` functions for
IEEE-754 arithmetic and `compare_mixed`; the loader establishing
`wf_program` (also asserted at run time in `Machine::new`); Rust/Verus.

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

`tests/run_tests.sh` compiles each `tests/toit/*.toit` with this tree's
compiler, runs it on the C++ VM, dumps it, runs the interpreter with 64-bit
and 32-bit smis and with the verified step disabled, and diffs stdout plus
exit code. 14 programs: hello, collections, strings, blocks, non_local,
try_finally, exceptions, large_ints, floats, tasks (monitors, channels,
mutex, semaphore, Task.group), sleep_timers, maps, classes, smi_edges. All
pass. The host VM is 64-bit only; `smi_edges.expected32` holds the
hand-checked 32-bit expectation for the one line that legitimately differs.
About 55-60% of executed steps run through the verified code.

## Findings in the current VM

* **INVOKE_DIV with MIN_SMI / -1** computes `Smi::from(MIN_SMI / -1)`,
  which wraps back to MIN_SMI on 64-bit: `-(1 << 62) / -1` prints
  `-4611686018427387904` instead of `4611686018427387904`
  (`tests/toit/smi_edges.toit`). The spec reproduces it.
* **INTRINSIC_HASH_FIND, REBUILD state**: `PUSH(rebuild_block);
  PUSH(STACK_AT(OLD_SIZE))` reads `OLD_SIZE` after the first push, so the
  rebuild block receives the state slot (always 0) instead of the old size.
  Harmless for correctness (only the index size heuristic), reproduced in
  the spec.

## Places where the current bytecode format made the spec awkward

Input to the Phase 2 format revision.

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
