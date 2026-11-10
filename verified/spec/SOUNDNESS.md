# Soundness of the format-2 structural verifier

This document describes the machine-checked soundness proof of the
structural verifier of the revised bytecode format (format 2). The proof
is in Verus, in `src/v2/`. It contains no `assume`, `admit`,
`external_body` or `assume_specification`. The whole crate verifies in
about 17 s wall time: `verification results:: 652 verified, 0 errors`
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
```

In words: every state reachable from the initial state of an accepted,
correctly loaded program makes a step that is not stuck, and every
completion of a PRIMITIVE step is not stuck either. **No `Stuck` variant
remains possible.** The defined failures are ordinary outcomes, not
stuck ones:

* machine-raised exceptions (`raise`): lookup failure, as-check failure,
  code invocation failure (wrong block/lambda argument count), invalid
  program (run-time checked method ids, field indices, read-only
  objects, dynamic global indices, lambda captures), and missing,
  unimplemented or denied primitives (PRIMITIVE_LOOKUP_FAILED);
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
* `completion(p, s, module, index, o)` (`theorem.rs`): `o` is
  `prim_success(p, s, h2, v)` or `prim_failure(s, h2, v)` for any heap `h2`
  and value `v` with `prim_heap_ok(p, s.heap, h2) && good(h2, v)`, or
  `prim_missing(p, s)`, or (core primitives 115/116) the machine-completed
  `task_new_step` / `task_transfer_step` (task creation and switching).
* `continues(o, s2)`: `o == Next(s2)` or `o == Halt(s2, Yield)` (the
  scheduler resumes a yielded task in that state).
* `transition(p, s, s2)`: `small(s2)` and either `continues(step(p, s),
  s2)`, or `step(p, s)` is `Primitive(s1, module, index)` and some
  `completion` of it continues in `s2`.
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
   objects) and is neither a suspended stack (`Stack2`) nor an unwinding
   token (`Pending`); `globals0.len() == c.global_count` and every global
   is a value; every root and literal is a value. Today the dumped
   program heap is checked by `v2/heap_check.rs` (plain Rust, unverified)
   in `toit_spec_verify`; the Phase 4 loader must establish it.
2. **Primitives: `prim_heap_ok(p, h, h2)`** (`v2/sound.rs`), quantified
   over in `completion`: a primitive may only add objects
   (`h.len() <= h2.len() < 2^30`); it never changes an object's class; it
   neither changes nor creates suspended stacks (`Stack2`) or unwinding
   tokens (`Pending`), and does not turn an ordinary object into one; and
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
   `double_add/sub/mul` and `compare_mixed` are `uninterp` in the spec
   (`spec_helpers.rs`); the theorem holds for every interpretation of
   them, so they add nothing to the trusted base of the proof.

Non-vacuity: `theorem_initial` proves `reachable` and `wf` for the initial
state of every accepted, loaded program, so the invariant is satisfiable
whenever the hypotheses are; `accepts` holds for real compiler output
(431 of 431 compilable suite programs and the three system snapshots,
see Tests), and the loader contract is what the VM's program heap
satisfies (checked by `heap_check.rs` on the same dumps).

## The invariant

`wf(p, c, s)` (`v2/sound.rs`):

* `heap_ok`: every object is well formed (`basic_obj_ok`), and every
  suspended task (`Stack2`) either never ran (its code is a value) or is
  itself a well-formed task (`wf_task`) stopped at a `task_transfer`
  PRIMITIVE (`at_transfer`);
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
a reference into a frame below with `good_ref`; `Token` — null or an
unwinding token whose pending unwinding can complete (`pending_ok`:
non-local returns and branches target frames at or below, branches to a
mapped offset whose map is a prefix of the target frame's kinds).

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
| `sound_unwind.rs`, `sound_return.rs`, `sound_raise.rs` | entering finally code, returns, the unwinding loop, raised exceptions |
| `sound_ctx.rs` | the verifier's context chain is the frames' context chain |
| `sound_heap.rs` | field writes and object replacement |
| `sound_instr.rs` | facts at the current instruction, the opcode families |
| `sound_local_ops.rs` | locals, constants, globals, POP, ALLOCATE, IS/AS, IDENTICAL, branches, HALT |
| `sound_field.rs`, `sound_block.rs` | field access; LOAD_OUTER, STORE_OUTER, LOAD_BLOCK, LOAD_OUTER_BLOCK |
| `sound_call_ops.rs` | lazy globals, INVOKE_STATIC, INVOKE_BLOCK, TRY |
| `sound_virtual.rs` | virtual calls, field-accessor and operator fast paths, `fast_at` |
| `sound_tail.rs` | INVOKE_STATIC_TAIL, INVOKE_LAMBDA_TAIL, INVOKE_INITIALIZER_TAIL |
| `sound_unwind_ops.rs` | THROW, RETURN(_NULL), NON_LOCAL_RETURN, NON_LOCAL_BRANCH, UNWIND |
| `sound_prim.rs` | PRIMITIVE completions, task creation and switching, the initial state |
| `sound_step.rs`, `theorem.rs` | the dispatch and the theorem |

Remaining obligations: none inside the proof (no per-opcode lemma is
left unproven, no admits). Outside it:

* the loader contract (hypothesis 1) is only checked by unverified Rust
  (`heap_check.rs`) today;
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

`v2/check.rs::verify(p, c, trusted)` is proven to return exactly
`accepts(pview2(p), c@, trusted)`; it uses loops only (no recursion over
the program size). `toit_spec_verify` (`src/bin/toit_spec_verify.rs`)
loads a dumped format-2 program, checks the program heap
(`heap_check.rs`), infers a certificate (`infer.rs`, untrusted),
runs `verify`, and prints the verdict, rejection reasons and the set of
referenced primitives (`--time` adds timings). The verdict depends only on
`verify`; inference and the heap check can only cause rejections.

## Changes made for the proof

The step function (`spec.rs`) and the abstract types (`types.rs`) are
unchanged. The verifier (`verifier.rs`, mirrored in `check.rs`; the
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

## Tests

* `tests/verify_suite.py`: every program found by `run_suite.py`
  (435 sources) compiled with `-Xbytecode_format=2`: 431 accepted, 4 do
  not compile (the `-force` negative compiler tests). Results in
  `tests/verify-results.txt`.
* `tests/system_snapshots.sh`: the three system snapshots (toit,
  toit.run, run-image) compiled with `toit.compile -Xbytecode_format=2`
  are accepted (trusted), referencing 176, 106 and 116 primitives.
  Verification time of the toit_run snapshot: 37.6 ms in total (load
  1.6 ms, inference 33.0 ms, check 4.6 ms); the largest (toit) takes
  198 ms.
* `tests/mutation_campaign.py --count 18000 --seed 2` (results in
  `tests/mutation-results.txt`, 55 s on 12 jobs): 11,400 single-byte and
  single-operand mutants of 60 programs (5,684 random instruction bytes,
  4,599 operands, 1,117 method-header bytes), verified with
  `trusted = false`. 8,966 are rejected (690 of them already by the
  method-table decoder); the 2,434 accepted ones were run on the reference
  interpreter for at most 100,000 steps each: 2,199 exited, 133 hit the
  step limit, 74 deadlocked (all tasks blocked), 13 called an
  unimplemented primitive, 12 ended with an uncaught exception, 3 tasks
  returned. **None got stuck or panicked the interpreter.**
