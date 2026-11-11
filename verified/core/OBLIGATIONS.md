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
| primitives | PRIMITIVE: the policy's core arities, the Rust ports (`prims::call`, no GC point, no save/reload) for 106 core primitives, else lookup, arity, C++ call; completion by status (`theorem::completion`) | primitive.rs, prims/ | the frame-height check |

## 2. Open obligations

### R. Paths still assumed

None: every path of every opcode is proven against the spec's completed
outcomes (`step::advances`, `theorem::outcome`). What remains assumed is
the leaf contracts (TRUSTED.md section 6): the C++ calls on these paths
(`gc_allocate_instance`, `gc_allocate_double`, `gc_allocate_exception`,
`gc_grow_stack`, `gc_call_primitive`).

Open:

- R-prims: done (branch core/prims-integration): the verified PRIMITIVE
  handler runs `prims::call` where the policy's core arities allow it
  (`primitive::op_rust_primitive`), proven to be a completion of the step
  (`lemma_completion`); the heap model is V5 (the primitives return
  `NotPorted` for opaque byte arrays).
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
  primitives are ported to Rust, proven against `prim_spec` (`prims::call`,
  TRUSTED.md section 8) and run by the verified PRIMITIVE handler for
  every program on the verified loop (untrusted programs); the
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

- Done (Phase 5): the core is 32-bit clean and verified for both widths
  (DESIGN.md section 3a; verified/check.sh runs Verus for the host and for
  `i686-unknown-linux-gnu`). The handler and the finally-record target
  are two words each (5-word records), the Stack header packs `rtop |
  ftop << 16`, block references are `frame << 16 | slot`.
- Done (Phase 5): the core is `no_std` + alloc (vstd without std, rlib
  only); the device library (vmverify `device-runtime`) supplies allocator
  and panic handler; it builds for riscv32imac (PROGRESS.md "Phase 5").

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

### Device size requests (branch device/certificate-and-size)

Status (branch core/fast-loop-proven, 2026-11-11): D1 and D2 are applied
as proposed (`machine::run`: the `None` arm is `run_checked` with
`checked-loop`, else a FATAL stuck report and `TERMINATED` without running
an instruction, TRUSTED.md section 4; ffi.rs: the five layout exports
behind `layout-tables`). D3 is open.

The device library is built without the cargo features `checked-loop` and
`layout-tables` (verified/core/Cargo.toml; both default on, forwarded by
verified/vmverify; CMake `TOIT_VERIFIED_CORE_CHECKED_LOOP`, off for
embedded builds). The features exist and the C++ side already refuses
unverified format-2 programs without the checked loop
(`ProcessGroup::create`, `V2MethodTable::checked_loop_linked`); the core
code does not use the cfgs yet. verified/check.sh runs Verus with both
features, so the verified code is unchanged; the device build only leaves
code out. Measured with the patch below applied to a copy
(artifacts device-cert/requested-core-patch.diff, scripts/libsizes.sh,
verified/vmverify/README.md "Device size").

- D1 (checked loop, -29 to -32 KB of text at opt 3/s/z, of which 10-11 KB
  are cold paths only the checked loop reaches). In `machine::run`:

  ```rust
  match accepted {
      Some(token) => crate::step::run_loop(&mut m, &env, &token),
      #[cfg(feature = "checked-loop")]
      None => run_checked(&mut m, &env),
      #[cfg(not(feature = "checked-loop"))]
      None => {
          env.rt.report(V2_REPORT_STUCK, m.bci, stuck::FATAL);
          (RESULT_TERMINATED, 1)
      }
  }
  ```

  Optionally the same cfg on `run_checked`, `dispatch_checked` and the
  handlers only they use (the linker drops them anyway; the crate allows
  dead code). Keep the arm wherever the rewritten run loop chooses between
  the verified and the checked loop.
- D2 (layout tables, -7.6 KB of rodata at opt s and z, 0 at opt 3). In
  ffi.rs, `#[cfg(feature = "layout-tables")]` on `toit_vcore_opcode_length`,
  `toit_vcore_layout_count`, `toit_vcore_layout_entry`,
  `toit_vcore_prim_count` and `toit_vcore_prim_entry` (and their tables).
  Only verified/layout_check.cc calls them (hosts). As `#[no_mangle]`
  exports of the static library LTO keeps them, and at opt s/z their name
  strings land in the merged `.rodata.str1.1` section, which the firmware
  link cannot garbage-collect even when the functions are dropped
  (vmverify's own tables are cfg'd the same way, on `std`).
- D3 (RAM, for discussion): `V2Method` is 20 bytes per method and the VM
  holds one table per running format-2 program and one during install-time
  verification: 19-35 KB for 0.9-1.8 K methods, more than the verifier's
  own peak with a shipped certificate (11-18 KB). A 16-byte record (e.g.
  `end` as a u16 length, `unused` dropped) or the decoded table stored in
  the image (borrowed from flash, as the certificate is) would cut it;
  both change the core's and the verifier's `VMethod` view.

## 3. Spec requests from the refinement proof

For verified/spec/format/PHASE4-REQUESTS.md (not edited here: owned by
the spec work).

- R6 resource failures: done (spec `prim::resource_throw`, merged from
  spec/raise-and-resources); the core's ALLOCATE, double arithmetic and
  stack growth implement it.
- R7 traces of raised failures: done (spec `Outcome2::Raise`,
  `prim::raised`); the core's raise implements it (raise.rs).
