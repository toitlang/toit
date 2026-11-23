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
the spec's). Since branch core/size-diet every opcode has one handler, on
the registers (`step::step_r`; the files below hold its helpers and the
shared machine-form code of the slow paths, `step::slow`):

| Family | Opcodes | File | Run-time checks removed |
|---|---|---|---|
| locals | LOAD_LOCAL(_WIDE), LOAD_LOCAL_0..5, POP_LOAD_LOCAL, STORE_LOCAL, STORE_LOCAL_POP | regs.rs | slot exists |
| constants | LOAD_LITERAL(_WIDE), LOAD_NULL, LOAD_SMI_0/1/U8/U16/U32, LOAD_SMIS_0, LOAD_METHOD | regs.rs | literal index, method id |
| globals | LOAD/STORE_GLOBAL_VAR(_WIDE), LOAD/STORE_GLOBAL_VAR_DYNAMIC, LOAD_GLOBAL_VAR_LAZY(_WIDE) | regs.rs, rblocks.rs, globals.rs | global index (static), slot, entry method checks |
| stack | POP, POP_1 | regs.rs | frame height |
| branches | BRANCH*, BRANCH_BACK* | regs.rs, step.rs | target in method, direction, zero distance |
| dispatch | every verified opcode | step.rs | instruction inside the method (the `mend`/`mfast` cache is gone) |
| calls | INVOKE_STATIC, INVOKE_VIRTUAL(_WIDE), RETURN, RETURN_NULL | rcalls.rs, calls.rs | target valid, arity, frame height, dispatch range, lookup entry, handler of the returning frame, caller frame, push room after return |
| fields | LOAD_FIELD(_WIDE), LOAD_FIELD_LOCAL, POP_LOAD_FIELD_LOCAL, STORE_FIELD(_WIDE/_POP), LOAD_FIELD_THIS, STORE_FIELD_THIS, INVOKE_VIRTUAL_GET/SET | rfields.rs, fields.rs | the `this` variants have none left (receiver, field range, task fields); others keep only `field_readable`/`field_writable` (spec checks) |
| type checks | IS_CLASS(_WIDE), IS_INTERFACE(_WIDE), AS_CLASS(_WIDE), AS_INTERFACE(_WIDE), AS_LOCAL | rfields.rs, types.rs | check-table indices, value has a class |
| blocks | LOAD_BLOCK, LOAD_OUTER, STORE_OUTER, LOAD_OUTER_BLOCK, INVOKE_BLOCK | rblocks.rs, blocks.rs | block reference decoding (frame, slot ranges), outer slot bounds, block method checks, LOAD_BLOCK encoding limits |
| operators | INVOKE_EQ..INVOKE_MOD, IDENTICAL: smis, doubles, large integers, `compare_numbers`, double arithmetic (a GC point), contents of strings/doubles/large integers, the virtual-call fallback | rops.rs, ops.rs, numbers.rs | operand slots |
| collections | INVOKE_AT, INVOKE_AT_PUT, INVOKE_SIZE on arrays, lists (array- and large-array-backed), byte arrays, slices, copy-on-write byte arrays, large arrays (`fast_at` with fuel, `fast_size`), else the virtual call | rarrays.rs, arrays.rs | slots |
| allocation | ALLOCATE(_WIDE), out of memory (resource throw) | rarrays.rs, alloc.rs, unwind.rs | class range, instantiable, the reload checks after the GC |
| halt | HALT 0..3 | halt.rs | slot |
| tail calls | INVOKE_STATIC_TAIL, INVOKE_LAMBDA_TAIL, INVOKE_INITIALIZER_TAIL (`replace_frame`; lambda method id, kind, captures and initializer id checked at run time as the spec checks them) | rblocks.rs, tail.rs | frame height, receiver, handler of the frame |
| raise | every raised failure (`Outcome2::Raise` completed by `prim::raised`: exception allocation, then the verified unwinding; out of memory: throw of roots[4]) with format 1's message words | raise.rs | the exception class check (from the spec's not-stuck completion) |
| resources | stack growth (`grow`), stack overflow (raise of roots[28]), out of memory in ALLOCATE and double arithmetic: `prim::resource_throw` | step.rs, unwind.rs, ops.rs | the reload checks after growth |
| primitives | PRIMITIVE: the policy's core arities, the Rust ports (`prims::call`, no GC point, no save/reload) for 106 core primitives, else lookup, arity, C++ call; completion by status (`theorem::completion`) | rarrays.rs, primitive.rs, prims/ | the frame-height check |

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
  the arity of verified/spec/src/v2/prim_arity.rs. 106 of the 143 allowed
  primitives are ported to Rust, proven against `prim_spec` (`prims::call`,
  TRUSTED.md section 8) and run by the verified PRIMITIVE handler for
  every program on the verified loop (untrusted programs); the
  remaining 37 (task, message, time, encoding and formatting primitives,
  bitmap) are reviewed C++ (TRUSTED.md section 8).
- S2 loader: `theorem::loaded` (the tables are an accepted program with
  `loaded_ok`, the first task encodes `initial_state`). Discharged for
  untrusted launches by verified/vmverify (`check::verify == accepts`,
  `x_loaded_ok == loaded_ok`, on the tables the core executes); the core
  runs the verified loop only for accepted programs
  (`toit_v2_context.accepted`). Trusted: the conversion
  verified/vmverify/src/from_vm.rs and the binding of the concrete task,
  stack and method table to the spec's initial heap. The
  [native frame check](../cxx/harness/prepare_process_v2.cc) exercises
  `prepare_process_v2` with a valid task and stack, symbolic method and dispatch tables,
  either entry selection, and symbolic stack length and contents.
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

- Done (branch core/size-diet): the `cold!` trampoline passes the machine
  by reference (no `ptr::read`/`ptr::write`, no unsafe left in it).
- GC safety of words held across a GC point in the checked handlers is by
  review (the verified handlers hold none: a GC point re-derives every
  word from the model).

### Device size requests (branch device/certificate-and-size)

Status (branch core/fast-loop-proven, 2026-11-11): D1 and D2 are applied
as proposed (`machine::run`: the `None` arm is `run_checked` with
`checked-loop`, else a FATAL stuck report and `TERMINATED` without running
an instruction, TRUSTED.md section 4; ffi.rs: the five layout exports
behind `layout-tables`). D3: the 16-byte record is applied (branch
core/trusted-integration, 920fb95d, a6f2abd5): `entry` and a 16-bit
`length`, `unused` dropped, in the core (ffi.rs `V2Method`, `end()` and
`end_spec`: `entry + length` modulo the word size, so a wrapped end lies
below `entry` and the verifier rejects the method), the spec's view
(vprog.rs `VMethod`; encode.rs, infer.rs and the tools only read
`end()`), C++ (`V2Method`, `V2MethodTable::compute` rejects bodies of
64 KB or more) and the layout check. 20 -> 16 bytes per method at install
and per running format-2 program (-3.6 to -7.2 KB for 0.9-1.8 K methods;
is-as-many-test 28.7 -> 23 KB); richards -0.2 %, deltablue/pystone +0.1
/ +0.2 % (x86-64 instructions, trusted). The headers read in place from
flash were not tried: every call reads the callee's entry, arity and
receiver range, which a LEB128 decode (format note 15) would add to.

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

  Request (branch device/esp32-build-fixes, 2026-11-11; measured under
  QEMU on the classic ESP32 without PSRAM, PROGRESS.md "Device builds"):
  at install the table is the largest single allocation (16-25 KB for the
  suite tests, 28 KB for is-as-many-test, whose `calloc` fails with 35 KB
  free and a largest block of 20 KB). The VM side now retries the install
  after a cross-process GC; the record itself needs this change in the
  core (and the same in the spec's view, verified/spec/src/v2/vprog.rs,
  owned by the spec):

  ```rust
  // verified/core/src/ffi.rs (and spec/src/v2/vprog.rs `VMethod`): 16 bytes.
  #[repr(C)]
  pub struct V2Method {
      pub entry: u32,      // absolute bci of the first instruction
      pub length: u16,     // end - entry (was `end: u32`)
      pub selector: u16,
      pub aux: u16,
      pub recv_start: u16,
      pub recv_end: u16,
      pub arity: u8,
      pub kind: u8,        // `unused: u16` dropped
  }
  ```

  Every reader of `end` uses `entry + length` (as u32: no overflow, the
  loader keeps the bytecodes below `V2_MAX_TABLE`). The C++ side
  (src/interpreter_v2.h `V2Method`, `V2MethodTable::compute`, which then
  rejects a method body longer than 0xffff bytes: compiled code has at
  most 6 KB, the toit CLI's largest method) and verified/layout_check.cc
  follow in the same commit; the layout check catches a mismatch. Saves 4
  bytes per method at install and for every running format-2 program
  (5.6 KB for is-as-many-test). The larger saving, the table stored with
  the image in flash at install and borrowed from there, needs no core
  change but a flash layout change (the reservation must hold it; today
  the certificate block occupies the tail during verification).

### Device speed requests (branch device/hw-perf, 2026-11-12)

Measured on the boards (docs/format2-migration.md, "Devices: hardware
results", "Where the time goes"; artifacts
/home/flo/work/opentoit-sandbox-artifacts/hw-perf). Format 2 executes
about as many instructions as format 1 (service calls: 32.4 M vs 29.1 M
for 200 calls on the classic ESP32), but on the classic ESP32 (40 MHz DIO
flash, a 32 KB flash cache per core shared by code and data, a miss costs
microseconds) every function the core runs from flash costs cache misses,
while the C++ interpreter it replaces kept its loop and helpers (hash
find included) in IRAM. Of the extra
cycles of 200 service calls (+180 M), instruction-fetch stalls were 79 %,
data stalls 26 %. The device-library step can place any function by name
(Kconfig TOIT_VERIFIED_CORE_IRAM_FUNCTIONS, localize-libm.cmake), but the
classic ESP32 has no IRAM left: everything below needs room made inside
the core. Ranked by measured benefit per byte (PC samples per byte of
code in flash, all perfbench workloads, classic ESP32):

- S1 (largest): split `step::run_loop` into a hot part for IRAM and cold
  arms in flash, with stable names. Of its 28.3 KB, the 64-byte blocks
  that got any PC sample over perfbench and hwbench are 13.8 KB; 99 % of
  the loop's samples fall in 8 KB, 99.9 % in 12 KB; 15 KB never got a
  sample. A hot part of at most 14 KB frees 14 KB of IRAM on the classic
  ESP32: enough to turn `ESP_WIFI_RX_IRAM_OPT` back on (13.2 KB) or for
  every helper of S2. The renaming step needs one symbol (or a name
  pattern) per part; today it moves `step::run_loop` only.
- S2: these out-of-loop functions are hot (samples per byte; size at opt
  3, Xtensa): `rnonlocal::op_try_v` 3.3 (223 B), `prims::array::list_add`
  2.3 (212), `room::ensure_room_all` 1.3 (215), `prims::blob::json_skip_whitespace`
  1.3 (181), `rarrays::cxx_primitive_v` 1.2 (276), `prims::ints::int_arg`
  1.1 (60), `toit_v2_run` 0.8 (614), `prims::array::array_new` 0.8 (146),
  `machine::run` 0.75 (267), `prims::blob::string_length` 0.7 (101),
  `rnonlocal::op_non_local_return_v` 0.7 (423), `rnonlocal::ret_try_v` 0.6
  (63), `rhash::probe_x` 0.5 (600), `rhash::op_hash_find_v` 0.5 (1,159),
  `rarrays::cxx_primitive_rest` 0.4 (523), `rnonlocal::unwind_resume_v`
  0.4 (370), `rarrays::resume_r` 0.3, `rhash::hf_at_x` 0.3 (674),
  `prims::blob::blob_arg` 0.3 (1,105), `Machine::large_loc` 0.25,
  `step::slow` 0.2 (4,980: its hot arms are the resume after a failed C++
  primitive, which every `task_transfer` takes, and the preemption check;
  split them from the rest). `Machine::reload_cold` and
  `Machine::do_return` are out of line on Xtensa and RISC-V and hot in
  service calls. The first ten (3.8 KB) are in IRAM now on the classic
  ESP32 (service calls 1.02 s -> 0.71 s, format 1 0.56 s); with every
  one in IRAM (a firmware without Bluetooth, for the room) 200 service
  calls took 0.54 s, json 0.36 s (format 1: 0.56 / 0.44 s).
- S3: the finally records move on every call and return
  (`Machine::call`, calls.rs `copy_within(f, f + FRAME_WORDS, e - f)`,
  `pop_frame_record`): inside any `try` (monitors, service handlers, task
  code) each call does a ROM memmove of all records above the frames. It
  is 9-12 % of the busy time of task switching (tasks-1k: 9.3 % on the
  ESP32, 12 % on the C6) and 1-4 % of the other workloads. Request a
  layout in which pushing or popping a frame record does not move the
  finally records (e.g. records growing from the other end of their
  region, or linked per frame).
- S4: `ensure_room_all` walks every frame of the stack (O(depth)) on the
  resume paths (room.rs:181, step.rs:686): 7.8 % of tasks-1k on the C6,
  2.2 % on the ESP32. Request a check of the top frame (or an incremental
  bound) where the state allows it.
- S5: `toit_v2_run` builds the `exec::Program` (about 30 words from the
  context, the built-in class ids and the roots read from the program in
  flash) on every process entry: 400 entries per 200 service calls, 4 %
  of their busy time from flash before it moved to IRAM. A `Program`
  prepared once per process group (and passed by pointer) would avoid the
  flash reads on every entry.
- S6 (data): data stalls were 26 % of the extra cycles of service calls
  (ESP32: 88 M vs 42 M cycles for 200 calls). Reads from the program in
  flash per call (the method record, the literal, the dispatch entry)
  compete with code for the same cache; fewer distinct lines touched per
  call helps.

Install-time verifier (owned with the spec): on the classic ESP32 the
check of a 25-31 KB program executes 270-490 M instructions (about 10-16
thousand per bytecode byte) at 2.4-2.5 cycles each; instruction-fetch
stalls are 18-21 % of its cycles; opt-level 3 (+11 KB) or s (+2 KB)
instead of z changed its time by under 5 %. malloc/free (the Rust
allocations go through ESP-IDF's heap_caps layers, in flash in the
format-2 sdkconfig of the classic ESP32) took about a third of the
verifier's busy samples. Requests: V1 fewer allocations (reuse the
per-method vectors across methods, or an arena per method check); V2
fewer instructions per bytecode.

## 3. Spec requests from the refinement proof

For verified/spec/format/PHASE4-REQUESTS.md (not edited here: owned by
the spec work).

- R6 resource failures: done (spec `prim::resource_throw`, merged from
  spec/raise-and-resources); the core's ALLOCATE, double arithmetic and
  stack growth implement it.
- R7 traces of raised failures: done (spec `Outcome2::Raise`,
  `prim::raised`); the core's raise implements it (raise.rs).
