# Soundness of the format-2 structural verifier

This document describes the machine-checked soundness proof of the
structural verifier of the revised bytecode format (format 2). The proof
is in Verus, in `src/v2/`. It contains no `assume`, `admit`,
`external_body` or `assume_specification`. The whole crate verifies in
about 20 s wall time: `verification results:: 718 verified, 0 errors`
about 25 s wall time: `verification results:: 736 verified, 0 errors`
(`verus --crate-type=lib src/lib.rs`).

## The theorem

`src/v2/theorem.rs` is short and meant to be read on its own:

```rust
pub proof fn theorem_soundness(p, c, trusted, heap0, globals0, s)
    requires
        accepts(p, c, trusted),             // the verifier accepts p with certificate c
        loaded_ok(p, c, heap0, globals0),   // the loader's contract
        reachable(p, heap0, globals0, s),   // s is reachable in any number of transitions
    ensures
        !(step(p, s) is Stuck),
        forall|s1, module, index, o|
            step(p, s) == Outcome2::Primitive(s1, module, index)
                && completion(p, s1, module, index, o) ==> !(o is Stuck),
        forall|o| outcome(p, s, o) ==> !(o is Stuck) && !(o is Raise),
        machine_objects_ok(p, s),
```

In words: every state reachable from the initial state of an accepted,
correctly loaded program makes a step that is not stuck, every
completion of a PRIMITIVE step is not stuck either, and neither is any
outcome of the state with its oracle steps completed (`outcome`: raises
completed with the machine's trace or out of memory, PRIMITIVE
completions, resource throws). **No `Stuck` variant remains possible.** Moreover the objects the machine interprets itself
keep the meaning it gives them (`machine_objects_ok`): every task's stack
field refers to a stack object (or is the smi 0 once the task has
terminated), its id is a smi, and the running task's stack field refers
to a stack object. See "Machine-interpreted objects" below for the other
objects the VM interprets. The defined failures are ordinary outcomes, not
stuck ones:

* machine-raised exceptions (`raise`, an oracle step `Outcome2::Raise`
  completed by `prim::raised`: the exception with any trace in a heap
  extended under the primitive contract, or the out-of-memory error when
  its allocation fails): lookup failure, as-check failure, code
  invocation failure (wrong block/lambda argument count), invalid program
  (run-time checked method ids, field indices, read-only objects, dynamic
  global indices, lambda captures), and missing, unimplemented or denied
  primitives (PRIMITIVE_LOOKUP_FAILED);
* resource throws (`prim::resource_throw`), only where the machine grows
  its stack (calls, virtual calls, operators, tail calls, TRY, lazy
  globals: out of memory or stack overflow), allocates an instance
  (ALLOCATE: out of memory) or a double (INVOKE_ADD/SUB/MUL: the
  operator's method is called instead), and a primitive's out-of-memory
  result (`PrimRet::OutOfMemory`, raised);
* `Outcome2::Halt`: uncaught exception, task end, exit, deep sleep and
  reset;
* out-of-memory: there is no transition to a state that exceeds the
  memory bound `small` (see below).

`trusted` selects the HALT rules: `accepts(p, c, false)` (the untrusted
instance, the one the sandbox relies on) rejects HALT 2 and 3 (deep sleep,
reset); `accepts(p, c, true)` (system programs) permits them. The theorem
holds for both.

### Definitions used by the statement

All are `open` spec functions; `step` is `#[verifier::opaque]` only to
keep proofs fast (it is unfolded with `reveal(step)` in the per-opcode
lemmas).

* `accepts(p, c, trusted)` (`v2/verifier.rs`): `wf_program2(p)` (table
  sizes), `tables_ok(p, c)` (dispatch table entries, method table,
  selector representatives and arities, builtin classes, entry points),
  and `method_ok` for every method: the certificate's map at offset 0 is
  the entry kinds, and every mapped offset is an accepted instruction
  (`instr_ok`) whose successors' maps agree. The certificate is computed
  by `v2/infer.rs` (untrusted); a wrong certificate can only cause a
  rejection.
* `step(p, s)` (`v2/spec.rs`): the format-2 step function (the
  specification, validated against the C++ VM, see DESIGN.md).
* `initial_state(p, heap0, globals0)` (`v2/prim.rs`): one frame of
  `__entry__main` with the main task on the stack.
* `completion(p, s, module, index, o)` (`theorem.rs`, the PRIMITIVE
  protocol of `prim.rs`): `o` is `prim_missing(p, s)`, or
  `prim_complete(p, s, h2, r)` for a heap `h2` and result `r`
  (`Success(v)`: return `v`; `Failure(v)`: push `v`, continue after the
  PRIMITIVE; `OutOfMemory(v)`: raise the resource error `v`) with
  `prim_returns(p, s, module, index, h2, r)`, i.e. in `prim_spec` (the
  default contract `prim_default`: `prim_heap_ok(p, s.heap, h2)`, results
  are values of `h2`; refined per primitive by `prim_refined`), or (core
  primitives 115/116, where a call returns only `OutOfMemory`) the
  machine-completed `task_step` (`task_new_step` / `task_transfer_step`:
  task creation and switching).
* `raised(p, s, v, o)` (`prim.rs`): `o` is `throw_exception(p, s', v, tr)`
  or `unwind(p, s', Throw(roots[4]))` where `s'` is `s` with a heap `h2`
  that extends `s.heap` under `prim_heap_ok` and `good(h2, tr)`;
  `completes(p, o, o2)`: `raised` for a `Raise`, else `o2 == o`.
* `resource_throw(p, s, o)` (`prim.rs`): see the defined failures above.
* `outcome(p, s, o)`: a completion (`completes`) of `step(p, s)`, of a
  `completion` of a PRIMITIVE step, or of a `resource_throw`.
* `continues(o, s2)`: `o == Next(s2)` or `o == Halt(s2, Yield)` (the
  scheduler resumes a yielded task in that state).
* `transition(p, s, s2)`: `small(s2)` and some `outcome(p, s, o)` with
  `continues(o, s2)`.
* `run(p, heap0, globals0, tr)`: `tr[0]` is the initial state and every
  `tr[i] -> tr[i+1]` is a `transition`; `reachable(..., s)`: `s` is the
  last state of some run.

## Hypotheses: the trusted contract for Phase 4

Each hypothesis is an obligation on the implementation.

1. **Loader: `loaded_ok(p, c, heap0, globals0)`** (`v2/sound.rs`):
   `heap0.len() < 2^29`; every program-heap object is `basic_obj_ok`
   (its class id is below the class count; objects of classes with
   fields are instances with exactly the class's field count; instance
   fields and array elements are smis or references to existing
   objects) and is neither a suspended stack (`Stack2`) nor a task (an
   object of the builtin task class), and every string holds
   well-formed UTF-8 (`utf8_ok`: no overlong encodings, surrogates or
   code points above U+10FFFF, as `Utils::is_valid_utf_8`; the soundness
   proof doesn't use it, and it is not part of the invariant `wf`: the
   primitives aren't proven to keep it); `globals0.len() == c.global_count`
   and every global is a value; every root and literal is a value.
   `v2/heap_check.rs::x_loaded_ok(p, c, heap, globals)` (Verus) is proven
   to return exactly `loaded_ok(pview2(p), c@, heap, globals)`
   (`x_loaded_heap_ok` the heap part, `loaded_heap_ok`); the VM can run
   it at an untrusted launch next to `check::verify`. What remains
   trusted is that the VM's loader hands the check the heap and globals
   the machine then runs on (the view of the loaded snapshot).
2. **Primitives: `prim_heap_ok(p, h, h2)`** (`v2/sound.rs`), quantified
   over in `completion` through `prim_default` (a primitive with a
   precise contract `prim_refined` must also satisfy that; the proof uses
   only `prim_default`). The same heap contract bounds what a raise
   allocates (`prim::heap_extended`): a primitive may only add objects
   (`h.len() <= h2.len() < 2^30`); it never changes an object's class; it
   neither changes nor creates suspended stacks (`Stack2`), and does not
   turn an ordinary object into one; it
   creates no task and keeps fields 0 and 1 (stack, id) of every task; and
   every object of `h2` is `basic_obj_ok` in `h2` (no dangling
   references, instance field counts preserved). Its result `v` must be
   a value of `h2` (`good`). Every primitive in the allowed set must be
   shown to satisfy this. The arguments a primitive receives are the
   frame's parameters (`prim_args`); the verifier checks the arity
   against the VM's primitive table `c.prim_arity` (`v2/prim_arity.rs`,
   generated from `src/primitive.h`), which must match the VM.
3. **Memory bound: `small(s)`** (`v2/sound.rs`): fewer than 2^30 heap
   objects, stack slots, frames and handlers. It is not an assumption
   that memory never runs out: `transition` only leads to `small`
   states, i.e. the model treats reaching the bound as the defined
   failure *out of memory* (the process stops). The implementation must
   stop (or raise out-of-memory) instead of creating a larger state. A
   step from a `small` state grows each size by a small constant, which
   the per-opcode lemmas use (`roomy`: below 2^31).
4. **Scheduler and messages**: none beyond `continues`. A yielded task
   resumes in the yield state; task switching happens only through the
   `task_transfer` primitive, completed by the machine
   (`task_transfer_step`, `resume`); the end of a task (`Halt`) is
   terminal for the theorem. Message delivery and other primitives are
   oracle completions under hypothesis 2.
5. **Specification inputs**: the floating-point operations
   `double_add/sub/mul` are `uninterp` in the spec
   (`spec_helpers.rs`); the theorem holds for every interpretation of
   them, so they add nothing to the trusted base of the proof.

### The theorem for a certificate checked one method at a time

The VM never holds a whole certificate (its maps are 24 bytes and more per
bytecode byte). `v2/split.rs` restates `accepts` per method:

* `GCert` is a certificate's global part (block-parameter masks,
  contexts, selector representatives, global count, primitive table)
  plus `pins`: the maps of other methods that a method's rules look up.
  Those are only the target map of a NON_LOCAL_BRANCH (in an outer method)
  and the task entry's map at offset 1 (`tables_ok`); every other rule
  reads only the method's own maps.
* `split_ok(p, g, ms, trusted)`: `wf_program2`, `tables_ok` against the
  pins only (`tables_cert(g)`), every method `m` accepted against its own
  maps `ms[m]` and the pins elsewhere (`local_cert(g, m, ms[m])`), and
  every pin equal to the map of its method at its offset (`pins_agree`).
* `lemma_split_sound`: `split_ok(p, g, ms, t) ==> accepts(p, with_maps(g,
  ms), t)` (the certificate assembled from the pieces).
* `lemma_split_complete`: `accepts(p, c, t) ==> split_ok(p, gcert_of(c),
  c.maps, t)` and `with_maps(gcert_of(c), c.maps) == c`. So
  `exists c. accepts(p, c, t)` iff `exists g, ms. split_ok(p, g, ms, t)`:
  nothing accepted is lost by checking piecewise.
* `theorem_soundness_split`: the theorem with `split_ok(p, g, ms,
  trusted)` and `loaded_ok(p, with_maps(g, ms), heap0, globals0)` as
  hypotheses (it applies `lemma_split_sound` and `theorem_soundness`).

Both lemmas rest on monotonicity (`lemma_method_ok_mono`,
`lemma_tables_ok_mono`): the rules compare other methods' maps with a
given sequence and never ask for their absence, so a certificate whose
maps agree wherever another's are present accepts at least as much.

Non-vacuity: `theorem_initial` proves `reachable` and `wf` for the initial
state of every accepted, loaded program, so the invariant is satisfiable
whenever the hypotheses are; `accepts` holds for real compiler output
(431 of 431 compilable suite programs and the three system snapshots,
see Tests), and the loader contract is what the VM's program heap
satisfies (checked by the verified `x_loaded_ok` on the same dumps).

## The invariant

`wf(p, c, s)` (`v2/sound.rs`):

* `heap_ok`: every object is well formed (`basic_obj_ok`), every task's
  stack field is a stack object or the smi 0 and its id a smi
  (`task_obj_ok`), and every suspended task (`Stack2`) either never ran
  (its code is a value) or is itself a well-formed task (`wf_task`)
  stopped at a `task_transfer` PRIMITIVE (`at_transfer`);
* `running_ok`: the running task is a task whose stack field refers to a
  stack object;
* `globals_ok`, `consts_ok`: globals, roots and literals are values;
* `wf_task`: frame bases are non-decreasing; every frame is `frame_ok`
  and every handler `try_ok`.

`frame_ok(p, c, s, fi)`: the frame's method is valid and checked; its
bci (the top's `s.bci`, else the return address of the frame above) is a
mapped offset whose map has one kind per slot (plus the pending result
`Val` for a suspended caller, or the finally triple `Val, Token, Val` for
a frame suspended in a TRY); every slot conforms to its kind (`conf`);
`this` of a method with a receiver range is in the range; a pinned
parameter 0 is still there.

`conf` by kind: `Val` — a smi or an existing object; `Method(t)` — the
smi `t`; `Block(0, i)` — a reference to slot `i` of this frame;
`Block(d > 0, i)` — a reference to slot `i` of the frame `d` contexts out
(following each block frame's own reference in slot 0), which holds a
block method whose context is that frame (`good_ref`), and for a block
frame's own reference the slot holds exactly the frame's method; `Param` —
a reference into a frame below with `good_ref`; `Token` — null or the smi
index of a finally record (`fin_ok`, format note 17) of this frame whose
token slot this is and whose unwinding can complete (`pending_ok`:
non-local returns and branches target frames at or below, branches to a
mapped offset whose map is a prefix of the target frame's kinds).
`fins_ok` (part of `wf_task`): the records belong to live frames, are
ordered by frame and height, and lie below the height of their frame's
active handler.

## Proof structure

`wf` holds initially (`sound_prim::lemma_initial`), is preserved by every
step and every completion, and implies progress; both are proven together
as `step_ok(p, c, s)` (`sound.rs`): the step's outcome is not stuck, a
next or yield state is `wf`, and for a PRIMITIVE outcome every completion
is (`completions_ok`). `sound_step::lemma_step` dispatches over eight
opcode families, each with its own lemma:

| File | Contents |
|------|----------|
| `sound.rs` | invariant, `outcome_ok`, `completions_ok`, `step_ok`, `loaded_ok`, `prim_heap_ok` |
| `sound_frames.rs`, `sound_upto.rs` | frames below the top and the heap growing keep conformance |
| `sound_local.rs` | `lemma_local_step`: steps that change only the top frame, the heap and the globals |
| `sound_call.rs` | `lemma_call`: pushing a frame |
| `sound_unwind.rs`, `sound_return.rs`, `sound_raise.rs` | entering finally code, returns, the unwinding loop, raised exceptions and their completions (`lemma_raised`) |
| `sound_ctx.rs` | the verifier's context chain is the frames' context chain |
| `sound_heap.rs` | field writes and object replacement |
| `sound_instr.rs` | facts at the current instruction, the opcode families |
| `sound_local_ops.rs` | locals, constants, globals, POP, ALLOCATE, IS/AS, IDENTICAL, branches, HALT |
| `sound_field.rs`, `sound_block.rs` | field access; LOAD_OUTER, STORE_OUTER, LOAD_BLOCK, LOAD_OUTER_BLOCK |
| `sound_call_ops.rs` | lazy globals, INVOKE_STATIC, INVOKE_BLOCK, TRY |
| `sound_virtual.rs` | virtual calls, field-accessor and operator fast paths, `fast_at` |
| `sound_tail.rs` | INVOKE_STATIC_TAIL, INVOKE_LAMBDA_TAIL, INVOKE_INITIALIZER_TAIL |
| `sound_unwind_ops.rs` | THROW, RETURN(_NULL), NON_LOCAL_RETURN, NON_LOCAL_BRANCH, UNWIND |
| `sound_prim.rs` | PRIMITIVE completions (including out of memory), task creation and switching, the initial state |
| `sound_resource.rs` | resource throws (`lemma_resource`) |
| `sound_prim_spec.rs` | the precise primitive contracts are satisfiable |
| `sound_step.rs`, `theorem.rs` | the dispatch and the theorem |

Remaining obligations: none inside the proof (no per-opcode lemma is
left unproven, no admits). Outside it:

* the loader contract (hypothesis 1) is checked by the verified
  `x_loaded_ok`; that its input is the machine's loaded heap is trusted;
* every allowed primitive must be shown to satisfy `prim_heap_ok`
  (hypothesis 2), and `prim_arity.rs` must match the VM's table;
* the memory bound (hypothesis 3) must be enforced by the implementation;
* the theorem is about the abstract step `spec.rs`; that it matches the
  C++ VM is established by differential testing (DESIGN.md), and the
  Phase 4 core must be proven against `spec.rs`;
* since the header shrink (format note 15) a method's `max_height` is the
  program's global maximum, so the verifier bounds each frame by that
  global value rather than a per-method one (still a static bound).

## The executable verifier

`v2/check.rs::verify(p, g, oracle, trusted)` is the streaming checker. It
takes the program as borrowed tables (`v2/vprog.rs::VProgram`, viewed as
`Program2` by `vview`; `vprogram_of` proves `vview` equal to `pview2` for an
`ExecProgram`), the certificate's global part `g` (`XGlobal`, viewed as a
`GCert`; byte tables borrowed from the certificate, selector records and
pins strictly sorted, looked up by binary search), and a
`MapOracle` that yields the maps of one method at a time (`XMaps`: maps as
lists of kinds sharing their bottoms). It checks the tables, then each
method in order against its maps and the pins, and drops the maps. It is
proven to return exactly

    g_ok(g) && split_ok(vview(p), g@, ms, trusted)

where `ms` (ghost) are the maps the oracle gave it; by `lemma_split_sound`
the certificate `with_maps(g@, ms)` is accepted. The oracle (the inference,
or the decoder of a shipped certificate) is untrusted: whatever it yields is
decided. `v2/cert.rs::verify_shipped(p, cert, global_count, prim_arity,
trusted)` runs it on a shipped certificate (format/18): the global part read
in place from the certificate bytes, the maps decoded one method at a time
from its stream; it is proven to return true only if some certificate with
that global count and primitive table is accepted. The checker uses loops only
(no recursion over the program size).

Out of memory: the checker and the decoder allocate fallibly
(`xvec::try_push` and friends) and return `Err(Oom)` when an allocation
fails; every result above holds for `Ok` (`res matches Ok(r) ==> ...`), and
the verdict rejects on `Err` (vmverify's OUT_OF_MEMORY). So the exactness of
`verify` is "exact unless it ran out of memory"; soundness only needs the
`Ok(true)` direction and is unaffected. Element accesses go through
`xvec`'s unchecked accessors, whose index preconditions Verus proves: the
device library has no panic path (verified/vmverify/README.md, "No panics
on devices").

`heap_check::x_loaded_ok_stream(p, objects, global_count, globals)`
checks the loader's contract one object at a time as an `ObjStream` yields
them (each with the number of objects found so far); it accepts only if
the heap the objects form satisfies `loaded_ok` for every certificate with
that global count (`lemma_loaded_obj_mono`: `loaded_obj_ok` reads the heap
only through its length). `x_loaded_ok(p, global_count, heap, globals)`
is the same for a heap in memory (proven equal to `loaded_ok`).

`toit_spec_verify` (`src/bin/toit_spec_verify.rs`) loads a dumped format-2
program, computes the global part (`infer::infer_global`, untrusted),
runs `verify` with the inference's oracle and `x_loaded_ok`, and prints the
verdict, rejection reasons and the referenced primitives (`--time` adds
timings). The VM (verified/vmverify) does the same on its own memory, with
`x_loaded_ok_stream`. Inference can only cause rejections.

## Changes made for the proof

Phase 4 changed the step function where it was more permissive than the
machine; each change is listed in `format/SPEC-CHANGELOG.md`:

* Core requests R7, R6 and S1 (2026-11-10): raising is an oracle step
  (`Outcome2::Raise`, completed by `raised`: the machine's exception
  carries a trace and is allocated at a GC point that may fail); stack
  overflow and out of memory are transitions where the machine can run
  out (`resource_throw`); PRIMITIVE follows the machine's protocol
  (`prim_returns`, `prim_complete`, `prim_spec` with per-primitive
  refinements). The step function's other results are unchanged.

* R5 (2026-11-10): the fields of a task the machine owns. The spec treated
  a task's fields 0 (its stack) and 1 (its id) as ordinary instance
  fields, so an accepted program could overwrite the stack field, which
  the VM then used as a stack (found by the core's end-to-end fuzzer,
  `verified/core/fuzz/findings/task-stack-field-store.snapshot`). The
  theorem did not exclude it because nothing in the abstract step reads
  the field except `task_transfer`, which treated a missing stack as a
  defined failure: the abstract machine keeps the running task's stack in
  the state, not in the heap, so the corruption was harmless in the model
  and fatal in the machine. Now field 0 is neither readable nor writable
  and field 1 read-only (`field_readable`, `field_writable`; the `this`
  variants are rejected by the verifier), a running task without its
  stack is `Stuck` in `task_transfer_step`, and the invariant carries the
  machine's view (`task_obj_ok`, `running_ok`), which the theorem states
  (`machine_objects_ok`). The table checks require the task class to be
  the only class with `TASK_TAG` and distinct from the exception class,
  so ALLOCATE cannot create a task and the machine's tag test agrees with
  the spec's class test.

* R1 (2026-11-10): unwinding without a heap token. A pending unwinding is
  a finally record next to the handlers (format note 17); the token is
  its index. The request's one record per frame was unsound for a
  try/finally inside finally code (an inner unwinding overwrote the outer
  record); the record stack with the ordering invariant `fins_ok` is
  proven instead. `Body::Pending` is gone, and with it the loader's and
  the primitives' obligations about unwinding tokens.

Before Phase 4 the step function was unchanged by the proof. The verifier (`verifier.rs`, mirrored in `check.rs`; the
equality proof still holds) was tightened where the proof found
accepted programs that get stuck:

1. `task_transfer` methods (PRIMITIVE core 116) must have plain `Val`
   parameters and no receiver range. Before, a method whose parameter
   kinds were e.g. `Method(t)` or a block reference could be accepted; a
   new task resumes that frame with fresh arguments (`resume`), so code
   after the PRIMITIVE could use a non-block as a block and get stuck.
2. IS_CLASS/IS_INTERFACE(_WIDE), IDENTICAL, LOAD_GLOBAL_VAR_DYNAMIC,
   LOAD_FIELD(_WIDE) and STORE_FIELD(_WIDE,_POP) must not consume the
   pinned `this` (slot 0 of a method with a receiver range): they now
   require `leaves0`, like calls already did. Before, e.g. LOAD_FIELD on
   a frame holding only `this` replaced it, and a later LOAD_FIELD_THIS
   got stuck.

All compiler output is still accepted (see Tests). The invariant itself
gained one clause during the proof (a block frame's own reference points
at a slot holding the frame's method), needed to relate the verifier's
context chain to the frames.

## What the VM checks outside the verifier (2026-11-10)

The verifier checks only the instructions at mapped (reachable) offsets;
the C++ loader (`V2MethodTable::compute`, src/interpreter_v2.cc) also
sweeps every method linearly and rejects bad opcodes, operands, branch
targets and `this` field indices in unreachable code. The end-to-end
fuzzer saw accepted mutants the loader refuses for that reason
(verified/core/PROGRESS.md). Decision: the verifier is right. The theorem
shows that every reachable state's bci is a mapped offset of its frame's
method (`frame_ok`), so unreachable bytes are never decoded by the
machine; the VM's only other decoder of format-2 code, the stack-trace
walk (`Stack::v2_frames_do`), decodes the current instruction with bounds
checks. The loader's per-instruction sweep is therefore redundant once
`check::verify` runs, and its extra rejections are harmless strictness;
the VM-linking work should drop it for verified launches (or keep it
knowing it rejects programs the verifier accepts).

What the VM must still do outside the verifier, and nothing else:

1. Decode the snapshot into the abstract program `pview2(p)` the verifier
   checks and the machine runs: the method table from the method headers
   (arity, kind, selector, receiver range, accessor field or capture
   count, body bounds), the dispatch table, class bits, builtin class
   ids, entry points, invoke offsets, roots and literals. The verifier
   re-checks every consistency property it needs (`wf_program2`,
   `tables_ok`, `method_ok`, including `entry < end <= len`); what it
   cannot check is that the decoded table is the one the machine uses.
2. Give the verifier the VM's primitive arities (`g.prim_arity`,
   `v2/prim_arity.rs` generated from src/primitive.h) and the program's
   global count, and run `check::verify(p, g, oracle, trusted)` with
   `trusted = false` for an untrusted launch.
3. Run `heap_check::x_loaded_ok_stream` on the loaded program heap (one
   object at a time) and globals.
4. Enforce the memory bound (hypothesis 3) and the primitive contract
   (hypothesis 2), as before.

## Machine-interpreted objects (audit, 2026-11-10)

R5 was a gap of one kind: the VM gives an object or field a meaning the
abstract model did not know, so the theorem said nothing about it. The
table lists every such place found by reading the VM (`src/objects.h`,
the interpreters, the encoders, `src/primitive_core.cc`), the format-2
core and the spec. "Proven" means a consequence of the theorem (the step
function cannot do it, or `machine_objects_ok`); "run time" means the
spec checks it at run time and the theorem shows the check is the only
way through; "trusted" means it rests on a hypothesis (loader, primitive
contract) or on C++ code outside the spec.

| Object / field | Interpreted by | Why a program cannot corrupt it, or why corruption is harmless | Status |
|---|---|---|---|
| Task field 0 (stack) | scheduler, task switch, GC (`Task::stack()`), core | not readable or writable by any opcode (`field_readable`/`field_writable`, `this_load_ok`/`this_store_ok`); primitives keep it (`prim_heap_ok`); only `task_new`/`task_transfer` set it | proven (`machine_objects_ok`) |
| Task field 1 (id) | `Task::id()` (`Smi::value` unchecked) | read-only for programs; primitives keep it | proven |
| Other task fields (`name_`, `state_`, ...) | Toit code only | the VM's `Task` has two fields | harmless |
| Task objects themselves | VM by `TASK_TAG` | only `task_new` creates them: ALLOCATE needs `INSTANCE_TAG`, the task class is the only `TASK_TAG` class (`task_class_ok`), none in the program heap (`loaded_ok`), none from primitives | proven + loader/primitive contract |
| Stack objects (`Stack2`) | GC, task switch, core (frames, handlers, bci inside) | reachable only through a task's field 0 (unreadable); no opcode writes a non-instance/array body; primitives neither change nor create them | proven + primitive contract (a primitive must not return one) |
| Frame and handler records | core (inside the stack object) | not addressable: the frame stack is separate, slot access is bounded by the top frame, block references are `(frame, slot)` checked by `ref_ok` | proven (`wf_task`) |
| Unwinding tokens and finally records | UNWIND, TRY, frame pops | the token is a smi naming a record (format note 17, no heap object); the verifier's `Token` kind cannot be copied, stored, passed or returned; UNWIND checks the record's frame and token slot; truncations never drop a record a live token names | proven (`fin_ok`, `fins_ok`) |
| Block method slots | INVOKE_BLOCK, TRY | referenced slots are not writable (`writable`); the method id is still checked (kind, index) | proven + run time |
| Lambda fields 0, 1 (method id, captures) | INVOKE_LAMBDA_TAIL | ordinary fields; method index, kind and capture count checked | run time (proven to be the only path) |
| Lazy initializer field (method id) | LOAD_GLOBAL_VAR_LAZY, `run-global-initializer__`, INVOKE_INITIALIZER_TAIL | class tested; the method id is checked (index, kind, arity 0) | run time |
| Exception objects (value, trace) | raise (writes a fresh object), Toit code, the trace encoder of the system | created fresh by the machine; programs may change them; consumers are Toit code and primitives that treat them as data | harmless |
| Oddballs, literals, roots | identity tests | `Oddball` bodies are not writable; roots and literals are values (`consts_ok`) | proven |
| Program heap (read-only) | machine (address range) | every write checks `ro` and raises | run time |
| Class ids, instance sizes | dispatch, GC, `basic_obj_ok` | no opcode changes a class; instances keep their class's field count | proven + primitive contract |
| Builtin tables (class ids, entry points, dispatch, selector and interface offsets) | machine | checked by the verifier (`tables_ok`) | proven (verified) |
| `List_` (array, size), `ListSlice_`, `Map_` (size, backing), `ByteArraySlice_`, `StringSlice_`, `ByteArrayCow_` | `fast_at`/`fast_size`, primitives, message encoder, error encoder | ordinary instance fields: any accepted program can set them to anything; every consumer must validate. The spec's `fast_at` does (falls back to a call); C++ consumers are trusted | run time (spec); trusted (C++) |

Further gaps found by this audit, all in trusted C++ consumers of the last
row (code reading; reaching them needs crafted bytecode, because library
privacy hides the fields from Toit source). They are memory-safety bugs of
the trusted base, not of the spec; entries 3-5 of `VM-BUGS.md` have the
details and fixes:

* `MessageEncoder` (`process_send`, untrusted-allowed): a `List_` size is
  not bounded by the backing array, a list slice's `from`/`to` are not
  checked against the backing, and `encode_map` scans the backing without
  bound: heap over-reads copied into another process's message.
* `EncodeVisitor::visit_instance` (`encode_error`, `encode_object`, and
  the format-2 raise path, which encodes the receiver of a failed
  lookup): `Smi::value` of an unchecked `List_` size, no bound by the
  backing length: heap over-read.
* `Object::byte_content` / `mutable_byte_content`: a `ByteArrayCow_` or
  slice whose backing is itself (or a cycle) recurses without bound: C
  stack overflow.

## Tests

Numbers after the oracle raise, the resource throws and the PRIMITIVE
protocol (core requests R7, R6, S1; 2026-11-10, branch
spec/raise-and-resources): `verified/check.sh --tests` passed (Verus spec
718 / core 328 verified, 0 errors; escape-hatch audit passed, no new
allowlist entries; layout check; run_tests.sh 15/15; vmverify tests;
sandbox ctests 93/93). `run_suite.toit --format 2` over 428 tests: 274 pass
(the 273 below plus the new byte-content-depth-test), 137 unimplemented
primitive, 8 step limit, 2 nondeterministic, 4 compile errors, 3
primitive-oracle differences (events-primitive-group-test, and the new
object-encoder-limits/-list tests: the interpreter does not emulate the
program-oriented encoder). `verify_suite.toit`: 443 sources, 439 accepted,
4 do not compile. System snapshots: all three accepted (toit 176, toit.run
106, run-image 116 primitives; toit.run 36.5 ms). Mutation campaign
(`--count 18000 --seed 3`): 11,100 mutants, 8,091 rejected (703 by the
method-table decoder), 2,306 accepted and run: 2,073 exit, 144 step
limit, 71 deadlock, 11 uncaught, 6 unimplemented primitive, 1 task
returned; **0 stuck or interpreter panics**.

Numbers after the Phase 4 changes (R5, R1, R4; 2026-11-10):
Numbers after the Phase 4 changes (R5, R1, R4; 2026-11-10), updated for
the streaming checker (R8, branch spec/verifier-memory):

* `verified/tools/verify_suite.toit`: every program found by `run_suite.toit` and the
  spec test programs (443 sources) compiled with `-Xbytecode_format=2`:
  439 accepted (verdict `verify && x_loaded_ok`), 4 do not compile (the
  `-force` negative compiler tests); the same programs as with the
  whole-certificate checker, plus 5 new tests. Results in
  `tests/verify-results.txt`.
* `tests/system_snapshots.sh`: the three system snapshots (toit,
  toit.run, run-image) compiled with `toit.compile -Xbytecode_format=2`
  are accepted (trusted) and satisfy `loaded_ok`, referencing 176, 106
  and 116 primitives (still so with the streaming checker). Verification time of the toit_run snapshot before
  Phase 4: 37.6 ms in total (load 1.6 ms, inference 33.0 ms, check
  4.6 ms); the largest (toit) 198 ms (not remeasured: the machines were
  loaded during this run).
* `verified/tools/mutation_campaign.toit --count 18000 --seed 3` (streaming checker;
  results in `tests/mutation-results.txt`): 18,000 single-byte and
  single-operand mutants of 60 programs (8,982 random instruction bytes,
  7,197 operands, 1,821 method-header bytes), verified with `trusted =
  false`. 14,256 are rejected (1,136 of them already by the method-table
  decoder); the 3,744 accepted ones were run on the reference interpreter
  for at most 100,000 steps each: 3,422 exited, 172 hit the step limit,
  109 deadlocked, 14 called an unimplemented primitive, 26 ended with an
  uncaught exception, 1 task returned. **None got stuck or panicked the
  interpreter.** (Before, seed 2: 12,300 mutants, 2,450 accepted, none
  stuck.)
* `tests/run_tests.sh`: the 15 spec test programs (new:
  `finally_records`, try/finally inside finally code, breaks out of
  finally code, the value slot) produce the C++ VM's output in format 1
  and format 2, 64- and 32-bit.
* `run_suite.toit --format 2` over 423 suite tests: 273 produce the C++
  VM's output on the reference interpreter (64- and 32-bit; the 268 of
  the previous run among them), 135 use an unimplemented primitive, 8 hit
  the step limit, 2 are nondeterministic, 4 do not compile, and 1
  differs: `events-primitive-group-test`, which tests resource-group
  checks of the `events.*` primitives that the interpreter's primitive
  emulation does not model (a primitive-oracle difference, not a step
  difference). Per-test status in `tests/suite-status.txt`.
