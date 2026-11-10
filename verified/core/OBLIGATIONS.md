# Proof obligations of the verified core

What is proven about the core, and what is left. "Proven" means: Verus,
zero `assume`/`admit`, with only the trusted items of TRUSTED.md and
verified/TRUSTED.toml. Run `verified/check.sh` (the merge gate) to
reproduce. Architecture: DESIGN.md section 9.

Current result: see PROGRESS.md (core verified count and time).

## 1. What is proven

The end-to-end theorem (`src/theorem.rs`): for an accepted, loaded
program the verified run loop's precondition (`Machine::inv`: the machine
refines a well-formed state of an accepted program) holds on the first run
and on every later run; the run loop (`step::run_loop`, verified) never
fails a view precondition, never reports a stuck state of the spec and
takes no fatal path. It rests on the contracts of TRUSTED.md section 6,
among them the assumed refinement of the paths listed in section 2.

Proven refinement of `spec::step` (the handler's next state is exactly
the spec's; `step::verified_op` lists the opcodes the verified dispatch
handles itself):

| Family | Opcodes | File | Run-time checks removed |
|---|---|---|---|
| locals | LOAD_LOCAL(_WIDE), LOAD_LOCAL_0..5, POP_LOAD_LOCAL, STORE_LOCAL, STORE_LOCAL_POP | exec.rs | slot exists |
| constants | LOAD_LITERAL(_WIDE), LOAD_NULL, LOAD_SMI_0/1/U8/U16/U32, LOAD_SMIS_0, LOAD_METHOD | exec.rs | literal index, method id |
| globals | LOAD/STORE_GLOBAL_VAR(_WIDE), LOAD/STORE_GLOBAL_VAR_DYNAMIC, LOAD_GLOBAL_VAR_LAZY(_WIDE) | exec.rs, globals.rs | global index (static), slot, entry method checks |
| stack | POP, POP_1 | exec.rs | frame height |
| branches | BRANCH*, BRANCH_BACK* | exec.rs, step.rs | target in method, direction, zero distance |
| dispatch | every verified opcode | step.rs | instruction inside the method (the `mend`/`mfast` cache is gone) |
| calls | INVOKE_STATIC, INVOKE_VIRTUAL(_WIDE), RETURN, RETURN_NULL | calls.rs | target valid, arity, frame height, dispatch range, lookup entry, handler of the returning frame, caller frame, push room after return |
| fields | LOAD_FIELD(_WIDE), LOAD_FIELD_LOCAL, POP_LOAD_FIELD_LOCAL, STORE_FIELD(_WIDE/_POP), LOAD_FIELD_THIS, STORE_FIELD_THIS, INVOKE_VIRTUAL_GET/SET | fields.rs | the `this` variants have none left (receiver, field range, task fields); others keep only `field_readable`/`field_writable` (spec checks) |
| type checks | IS_CLASS(_WIDE), IS_INTERFACE(_WIDE), AS_CLASS(_WIDE), AS_INTERFACE(_WIDE), AS_LOCAL | types.rs | check-table indices, value has a class |
| blocks | LOAD_BLOCK, LOAD_OUTER, STORE_OUTER, LOAD_OUTER_BLOCK, INVOKE_BLOCK | blocks.rs | block reference decoding (frame, slot ranges), outer slot bounds, block method checks, LOAD_BLOCK encoding limits |
| operators | INVOKE_EQ..INVOKE_MOD (smi fast paths), IDENTICAL | ops.rs | operand slots |
| arrays | INVOKE_AT, INVOKE_AT_PUT, INVOKE_SIZE (plain-array fast paths) | arrays.rs | slots |
| allocation | ALLOCATE(_WIDE) | alloc.rs | class range, instantiable, the reload checks after the GC |
| halt | HALT 0..3 | halt.rs | slot |

## 2. Open obligations

### R. Paths still assumed (`step::step_unverified`)

The verified handlers hand the whole instruction (before any change) to
the checked handlers of machine.rs on these paths, whose refinement
contract is assumed:

| Item | Opcodes / paths | Missing |
|---|---|---|
| R-raise | every raised failure: INVALID_PROGRAM (fields, dynamic globals, HALT 1), AS_CHECK_FAILED (AS_*, receiver checks), LOOKUP_FAILED (virtual calls), CODE_INVOCATION_FAILED (INVOKE_BLOCK) | a verified `raise`: the exception allocation (a GC point, like `alloc::gc_allocate_instance`) and the unwinding loop `spec::unwind`; and spec request R7: the machine's exception carries a trace (the spec's has null), so the allocated object differs from `spec::exception_obj` |
| R-unwind | the raising entries into the unwinding (every raise above) | THROW, TRY, UNWIND, NON_LOCAL_RETURN and NON_LOCAL_BRANCH are verified with the finally records (src/unwind.rs: the loop `spec::unwind`, `enter_finally` with a record, `pop_frame`) |
| R-tail | INVOKE_STATIC_TAIL, INVOKE_LAMBDA_TAIL, INVOKE_INITIALIZER_TAIL | a verified `replace_frame` (copy_within of the arguments, the records of the replaced frame) |
| R-prim | PRIMITIVE | the C++ call (`toit_v2_call_primitive`) needs a contract: completion as `prim_success`/`prim_failure`/`prim_missing` with `prim_heap_ok` (S1), and the task primitives `task_new_step`/`task_transfer_step` |
| R-slow | operators on doubles, large integers, `compare_numbers` (`spec_helpers::compare_mixed`, uninterpreted in the spec), their virtual-call fallback; IDENTICAL of distinct heap objects (strings, doubles, large integers); INVOKE_AT/AT_PUT/SIZE on lists, byte arrays, slices, large arrays (`fast_at` with fuel) | heap-model accessors for doubles, byte arrays and strings; the float operations are uninterpreted in the spec, so their results can only be related by a trusted contract |
| R-oom | ALLOCATE out of memory | `resource_throw` (spec request R6) |

### G. Trusted contracts to discharge

- G-grow: `step::grow_bridge` (stack growth) is assumed to preserve the
  abstraction; prove `reload` after `toit_v2_grow_stack` like the reload
  after allocation (alloc.rs), with a growth contract stated over the
  stack model.
- G-gc: the GC preserves the abstraction (the contracts of
  `alloc::gc_allocate_instance` and of the bridges); trusted, Phase 4
  keeps the GC trusted.
- G-heap: `abs::heap_model_ok` (heap integrity) is maintained by the GC,
  the allocators and the C++ primitives; trusted.

### Obligations from Phase 3 (verified/spec/SOUNDNESS.md)

- S1 primitives: every allowed primitive satisfies `prim_heap_ok` and has
  the arity of verified/spec/src/v2/prim_arity.rs. 106 of the 154 allowed
  primitives are ported to Rust and proven against `prim_spec`
  (`prims::call`, TRUSTED.md section 7); open: the verified PRIMITIVE
  handler must call `prims::call` (branch core/refinement-2), and the
  remaining 48 (task, message, time, encoding and formatting primitives,
  bitmap) are reviewed C++ (TRUSTED.md section 7).
- S2 loader: `theorem::loaded` (the tables are an accepted program with
  `loaded_ok`, the first task encodes `initial_state`). Discharged for
  untrusted launches by verified/vmverify (`check::verify == accepts`,
  `x_loaded_ok == loaded_ok`, on the tables the core executes); the core
  runs the verified loop only for accepted programs
  (`toit_v2_context.accepted`). Trusted: the conversion
  verified/vmverify/src/from_vm.rs and `prepare_process_v2` building the
  initial state.
- S3 size bound `small`: implied by `refines` (stack below 2^20 words,
  heap model below 2^30 objects); exceeding it is a defined stop or a
  resource throw (R6).

### Other open items

- The `cold!` trampoline (`ptr::read`/`ptr::write` of the machine) is
  trusted; listed in TRUSTED.toml. Its comment assumes panic = abort; the
  VM's library (verified/vmverify) is built with panic = unwind. The
  machine has no destructor, so an unwinding panic inside a cold path
  leaves a stale but valid copy; the core's own code does not panic
  (verified code cannot; the checked handlers index only checked arrays).
  Review or switch the core's paths to abort.
- GC safety of words held across a GC point in the checked handlers is by
  review (the verified handlers hold none: a GC point re-derives every
  word from the model).

## 3. Spec requests from the refinement proof

For verified/spec/format/PHASE4-REQUESTS.md (not edited here: owned by
the spec work).

- R6 resource failures: the machine throws STACK_OVERFLOW when the stack
  cannot grow and OUT_OF_MEMORY when an allocation fails, and the program
  can catch them; the spec has unbounded memory, so these are not spec
  transitions. The core's theorem names them (`step::resource_throw`);
  request: model them as a defined raise (any state, value a root error)
  and prove it keeps `wf`.
- R7 traces of raised failures: the machine's `Exception_` carries a stack
  trace (and the format-1 message, R2); `spec::raise` builds one with a
  null trace. Request: let `raise` take the trace as an oracle value (any
  good value) so that the core's raise can refine it.
