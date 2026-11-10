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
takes no fatal path. It rests on the contracts of TRUSTED.md section 6:
the leaf contracts of the C++ calls (allocation, exception allocation,
stack growth, C++ primitives), each stated as an instance of a spec
transition, the heap model, the loader and the scheduler. Every opcode of
format 2 has a verified handler; `step_unverified` and `grow_bridge` are
gone (branch core/refinement-2).

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
| operators | INVOKE_EQ..INVOKE_MOD, IDENTICAL: smis, doubles, large integers, `compare_numbers`, double arithmetic (a GC point), contents of strings/doubles/large integers, the virtual-call fallback | ops.rs, numbers.rs | operand slots |
| collections | INVOKE_AT, INVOKE_AT_PUT, INVOKE_SIZE on arrays, lists (array- and large-array-backed), byte arrays, slices, copy-on-write byte arrays, large arrays (`fast_at` with fuel, `fast_size`), else the virtual call | arrays.rs | slots |
| allocation | ALLOCATE(_WIDE), out of memory (resource throw) | alloc.rs, unwind.rs | class range, instantiable, the reload checks after the GC |
| halt | HALT 0..3 | halt.rs | slot |
| tail calls | INVOKE_STATIC_TAIL, INVOKE_LAMBDA_TAIL, INVOKE_INITIALIZER_TAIL (`replace_frame`; lambda method id, kind, captures and initializer id checked at run time as the spec checks them) | tail.rs | frame height, receiver, handler of the frame |
| raise | every raised failure (`Outcome2::Raise` completed by `prim::raised`: exception allocation, then the verified unwinding; out of memory: throw of roots[4]) with format 1's message words | raise.rs | the exception class check (from the spec's not-stuck completion) |
| resources | stack growth (`grow`), stack overflow (raise of roots[28]), out of memory in ALLOCATE and double arithmetic: `prim::resource_throw` | step.rs, unwind.rs, ops.rs | the reload checks after growth |
| primitives | PRIMITIVE: lookup, arity, call, completion by status (`theorem::completion`) | primitive.rs | the frame-height check |

## 2. Open obligations

### R. Paths still assumed

None: every path of every opcode is proven against the spec's completed
outcomes (`step::advances`, `theorem::outcome`). What remains assumed is
the leaf contracts (TRUSTED.md section 6): the C++ calls on these paths
(`gc_allocate_instance`, `gc_allocate_double`, `gc_allocate_exception`,
`gc_grow_stack`, `gc_call_primitive`).

Open:

- R-prims: wire the Rust primitives of branch core/primitives
  (`prims::call`, proven against `prim_spec`) into `primitive::op_primitive`
  before the C++ bridge. Blocked on reconciling the heap models: that
  branch's `Heap` makes every byte-array-tagged object `Body::Bytes`
  (proxies included, content inaccessible), this branch makes proxies and
  mapped files opaque (TRUSTED.md V5) because `spec_helpers::fast_at`
  would read a proxy's bytes. Both branches add `Heap::double_bits` (same
  contract). Decide one model (V5 is the one INVOKE_AT can implement).
- R-trace: the C++ exception encoder reads the message words before its
  first GC point (`msg_ok` requires them to be values of the state);
  `toit_v2_allocate_exception` is the leaf contract.

### G. Trusted contracts to discharge

- G-grow: done: `step::grow` is verified; `gc_grow_stack` states the
  growth contract over the views (same state, room on success).
- G-gc: the GC preserves the abstraction (the contracts of
  `alloc::gc_allocate_instance` and of the bridges); trusted, Phase 4
  keeps the GC trusted.
- G-heap: `abs::heap_model_ok` (heap integrity) is maintained by the GC,
  the allocators and the C++ primitives; trusted.

### Obligations from Phase 3 (verified/spec/SOUNDNESS.md)

- S1 primitives: every allowed primitive satisfies `prim_heap_ok` and has
  the arity of verified/spec/src/v2/prim_arity.rs. 106 of the 154 allowed
  primitives are ported to Rust and proven against `prim_spec`
  (`prims::call`, TRUSTED.md section 8); open: the verified PRIMITIVE
  handler must call `prims::call` (branch core/refinement-2), and the
  remaining 48 (task, message, time, encoding and formatting primitives,
  bitmap) are reviewed C++ (TRUSTED.md section 8).
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
  resource throw (`prim::resource_throw`).

### Phase 5 (from the verifier-memory work)

- The core is not 32-bit clean: machine.rs (and the verified handlers)
  shift a `usize` by 32 for the handler word (`height | bci << 32`) and the
  finally-record target (`bci | height << 32`), and `abs::handler_word`,
  `target_word` assume 64-bit words. A 32-bit layout needs two words or
  16-bit halves.
- The core is not `no_std`: no `#![no_std]`, vstd with std, `staticlib`
  crate type with the hosted panic handler. Both block the riscv32 build
  (the verifier crates already build `no_std` + alloc).

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

- R6 resource failures: done (spec `prim::resource_throw`, merged from
  spec/raise-and-resources); the core's ALLOCATE, double arithmetic and
  stack growth implement it.
- R7 traces of raised failures: done (spec `Outcome2::Raise`,
  `prim::raised`); the core's raise implements it (raise.rs).
