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
and on every later run, and `src/process.rs` composes the two over any
number of runs (`theorem_process`, which also gives every state a run
starts in the conclusion of the spec's soundness theorem). The run loop
(`step::run_loop`, verified) never fails a view precondition; each step
reports a stuck result only for the resource limit (`step_post`), and
since 2026-11-26 (branch prims/trust-round) its exported contract
`run_post` says so for the run: `run_loop`'s ghost third result
(`RunEnd`) is an exit of a step or the reason of the run's one stuck
report, which is `stuck::LIMIT` or, before the first instruction,
`stuck::FATAL` for a program-heap range that wraps around (`stop_ok`).
The precondition of `run_loop` is not checked
at its call site (`machine::run`, plain Rust): that the runtime machine
satisfies `loaded` and `resumed` is the trusted glue of TRUSTED.md
section 6. It rests on the contracts of TRUSTED.md section 6:
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
- G-gc: a collection is a step of the spec (`toit_spec::v2::gc`, see
  "The collector" below), and the GC leaf contracts promise exactly
  collections; trusted until a collector proof delivers them.
- G-heap: `abs::heap_model_ok` (heap integrity) is maintained by the GC,
  the allocators and the C++ primitives; trusted.

### The collector (stage 0 of the collector proof plan, branch gc/stage0-spec)

The plan: /home/flo/work/opentoit-sandbox-artifacts/gc-proof-pilot/README.md
(section 5). Stage 0 makes the model say what a collection does, so that
a collector proof can discharge it.

What a collection is (verified/spec/src/v2/gc.rs, `collection`; any
number of them: `gc_steps`):

1. Weak processing (`zapped`, as `WeakMapFinalizerNode::weak_processing`
   and `zap_dead_values`): a mutable instance of the map class may be
   reset (size and spaces left 0, index and backing null), and a value
   slot (odd index) of an array of a map's backing (the backing list's
   array, or the arraylets of its large array) that holds an object
   other than a tombstone may become null. Over-approximated: the C++
   does it only for maps with a weak finalizer (a header bit the model
   lacks), resets only maps and nulls only values the strong marking did
   not reach. It writes the map's four fields and reads the list's and
   large array's without checks; the C++ verifier's
   `check_builtin_classes` gives those classes their fields and the map
   class the instance tag (not the task tag), which the step's guards
   (`is_map`, `inst_field`) mirror.
2. Compaction (`ren_ok`, `renamed`): a live set that holds the object
   stack, the globals and the running task and is closed under references
   (it may hold more: the collector's other roots) survives; garbage
   disappears; the live objects are renumbered `0..n` and their
   references renamed; the program heap and the program's constants keep
   their ids; frames, handlers, finally records, bci and task counter
   stay.

Proven: every collection keeps `wf` (`lemma_gc_steps_wf`) and a raise's
unwinding invariant (`lemma_gc_steps_unw`); an allocation commutes with
collections in which the new object survives (`lemma_gc_steps_alloc`);
a PRIMITIVE step and a double operator are the same step after them.

The core against it. `refines` is unchanged: after a compaction the
abstract heap holds only the live objects, so permissions and distinct
addresses for every object of the model are what a collector that frees
memory can give. (The alternative, stable ids with permissions only for a
live set, keeps every object ever allocated in the model: its length
passes `small`'s 2^30 objects and `Value::Obj`'s `usize` on 32-bit
within hours of allocation, and the 32-bit core derives that bound from
distinct addresses. Renumbering keeps it derivable.) The GC leaf
contracts promise a state that collections reach (`alloc::gc_alloc_post`,
`step::grow_post`, the exception and primitive contracts; none when the
epoch is unchanged); `step::advances` allows collections before and after
a step (`gc_around`); ALLOCATE and the double operators are the step
followed by the collections (`step::lemma_alloc_gc`); stack growth is
collections before the instruction; a C++ primitive is collections, then
a completion of the collected state (its source is a ghost machine,
`step::src_ok`); a raise's completion may collect first (spec,
`prim::raised_gc`); between runs `theorem::resumed` assumes collections
instead of the same state. The theorems' text is unchanged; their
`reaches` now includes collections (THEOREMS.txt, PROGRESS.md).

The two ends meet (verified/core/src/gcbridge.rs, proof only):
`lemma_collected` takes what a collector that keeps object identities
proves, `collected` (the pilot's contract restated for the core's model
and a whole collection: live set with the roots, closed, the program heap
its first `n0` objects; new tagged, distinct addresses; each live object
well formed under them), after weak processing, and shows that numbering
the live objects in order is a `collection` whose state the core's heap
model represents at the collector's addresses: `heap_model_ok`, every word
the collector left is the core's word of the renumbered object
(`view::word_val`), the roots are the encodings of the renumbered roots,
the program heap keeps its ids.

Still assumed about the collector (GC-class code, trusted), for stage 1+:

- The five restated leaf contracts and `resumed` (TRUSTED.toml): that the
  C++ collector delivers `gc_steps`. Through `gcbridge` a proof of
  `collected` for the real layouts (the 12 class tags, stacks, external
  byte arrays: stage 2) discharges the abstract half.
- The run-time half the bridge does not cover: the hand-over of the word
  permissions of the live objects (`view::HeapMem`, the views the
  contracts return), the remembered-set cards of every mutable object
  (`view::Heap`'s invariant; after a scavenge every old object holding a
  young reference must have a dirty card), the allocation window after a
  collection (`Runtime::allocation_window`, TRUSTED.md section 9), and
  to-space capacity (the pilot's `lemma_capacity`).
- Roots: `collected` needs the state's roots (object stack, globals,
  running task) in the live set; the collector's own roots (other tasks,
  process roots, messages, resources, finalizer lists, external roots)
  only make the live set larger. Completeness of the C++ root
  enumeration for everything the C++ later hands to the core (a message,
  a finalizer lambda from `next_finalizer_to_run`) is still a review item.
- Finalizers: a Toit finalizer's lambda keeps what it reaches alive (in
  the live set: no state change; the revived weak map reset is the weak
  step); VM finalizers free the external memory of dead strings and byte
  arrays (gone from the state; `gc_owns`, verified/CONTRACTS.toml). The
  finalizer header bit is not modeled.
- Stacks shrunk and moved during marking (`stack_copy_equiv`).
- The program heap as a prefix: `collected` assumes the first `n0` ids are
  exactly the read-only objects (true of `initial_state`: `heap0`, then
  allocations outside the program heap); the core does not carry it as an
  invariant yet, so a bridge to the live contracts needs it added to
  `refines` (and to the loader's assumption) first.

### Obligations from Phase 3 (verified/spec/SOUNDNESS.md)

- S1 primitives: every allowed primitive satisfies `prim_heap_ok` (which
  since 2026-11-26 also keeps every read-only object and `ro` flag:
  proved for the Rust ports, assumed of the C++ primitives) and has
  the arity of verified/spec/src/v2/prim_arity.rs. 106 of the 150 allowed
  primitives (141 core, 2 bitmap, 4 timer, 3 events) are ported to Rust, proven against `prim_spec` (`prims::call`,
  TRUSTED.md section 8) and run by the verified PRIMITIVE handler for
  every program on the verified loop (untrusted programs); the
  remaining 44 (task, message, time, encoding and formatting primitives,
  bitmap, timer, events) stay in C++ (status per primitive:
  verified/cxx/annotated/README.md) (TRUSTED.md section 8).
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
  The facts of `prog_rel` about the method table that the core reads
  without bounds checks (`vprog::table_ok`: every header inside the
  bytecodes with a canonical kind byte, and since branch
  core/call-speed-size every entry but a block's odd) and the 2-byte
  alignment of the bytecodes (`Table::even`, for the aligned header
  loads of `Table::u16_at_even`, TRUSTED.md section 1) are checked by
  `V2MethodTable::compute` (the validation loop and its helpers are
  proven, verified/cxx/annotated/README.md); `toit_v2_run` re-checks the
  alignment.
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

### Ports that never fall back (branch core/ports-never-fall-back)

Proved: for the 45 (index, arity) pairs of `prims::never_falls_back` (35
before branch prims/trust-round added list_add, the four byte-array
accessors byte_array_is_raw_bytes, byte_array_length, byte_array_at,
byte_array_at_put, and string_rune_count, blob_equals, blob_index_of,
compare_simple_json_string, size_of_json_number)
(prims/mod.rs, the one list; verified/CONTRACTS.toml `[unreachable]`
repeats it and contract_check.toit checks the two agree and that each
arity is `index::TABLE`'s) every port call completes in Rust:
`prims::call` ensures `module == 0 && never_falls_back(index, n) ==>
completes(r.0)` (Success or Failure, never NotPorted or NeedsGc), from
the same ensures of the four family dispatches and of the per-primitive
functions (`int_res`: a smi-range value is a Success; `lemma_smi_op`:
a smi's remainder and right shift are smis; `blob_or_fail`: a
STRINGS_ONLY decoding fails without NotPorted). `rarrays::rust_primitive_r`
(since 2026-11-26 gated by the policy's verifier table, `Program::policy`,
which is the certificate's primitive table) ensures: `module == 0 &&
never_falls_back(index, arity) ==> res is Some` (a denied primitive
completes with PERMISSION_DENIED, an allowed one runs its port), and that
when it returns None the primitive is allowed with the method's arity
(`prim_allowed`, `cert.prim_arity[module][index] == arity`).
`op_primitive` calls the C++ primitive only when `rust_primitive_r`
returns None.

What this rests on (no new trusted item; the paragraph describes the
gate before 2026-11-26, the core arities, which the verifier table
replaced: now nothing about the gate is assumed beyond the table being
the certificate's, `policy_rel`): the C++ body of such a
primitive runs on the verified loop only through `toit_v2_primitive`,
which runs it only when the policy's entry has the method's arity
(src/interpreter_v2.cc: ABSENT otherwise) and is the VM's own function
(a denied entry is `primitive_denied`). For the VM's own entry,
`PrimitivePolicy::initialize_core_arities` makes `core_arities[i]` that
entry's arity plus one (`toit_v2_core_ported` is 1 for the 35), so the
gate passes; and that arity is the list's (src/primitive.h against
`index::TABLE`: the layout check; `index::TABLE` against the list:
contract_check). Both are already trusted rows (TRUSTED.md: the policy
table, `prims/index.rs` `TABLE`); the Verus statement takes the arity as
a hypothesis (`never_falls_back(index, arity)`), so it is not assumed in
Verus. Stated narrowly, the environment fact is: where `core_arities[I]`
is non-zero it is `k + 1` for the listed `(I, k)` (equivalently, the
verifier's `cert.prim_arity[0][I]` is `k`). Derived policies share their
base's table (TRUSTED.md's existing row covers a derived policy denying
a primitive its base allows).

Other routes to these C++ bodies: the checked loop (`op_primitive_cold`,
hosts only, unverified trusted tables), the format-1 interpreter (trusted
format-1 programs only: untrusted format-1 programs are refused by every
build since `-Xuntrusted_format1` was removed). Dropping the 35 C++ bodies
from format-2-only firmware needs: no format-1 interpreter (so no trusted
format-1 programs), no checked loop (devices
already build without it), and their primitive-table entries kept with
their arity but without the function, with `initialize_core_arities`
deciding `own` for ported primitives without `original->function !=
null` (else the gate closes and every call reaches `toit_v2_primitive`,
which would then report the primitive absent). A link map (`nm`) of such
a build has to confirm that nothing else references them.

Not on the list, though close: `float_to_raw32` never falls back on
64-bit words only (a raw u32 is a smi there); `string_length` and
`json_skip_whitespace` fall back for lengths above MAX_SMI, unreachable
but not provable without a string length bound in the trusted heap model
(`obj_model_ok` bounds byte arrays, not strings: a trusted change), and
for a neutered byte array (json_skip_whitespace; both C++ bodies are
VeriFast-proved); `string_rune_count` and `size_of_json_number` now fail
with OUT_OF_RANGE there instead (branch prims/trust-round: the C++ made
the count a smi unchecked); `string_at` declines
invalid UTF-8 (where its C++ reads past the end; returning null there
would make it total, a behavior change).

### Other open items

- Done (branch core/size-diet): the `cold!` trampoline passes the machine
  by reference (no `ptr::read`/`ptr::write`, no unsafe left in it).
- GC safety of words held across a GC point in the checked handlers is by
  review (the verified handlers hold none: a GC point re-derives every
  word from the model).
- Done (branch device/memory-pressure): the slow-tier ESBMC job
  `task-all-fields` (verified/cxx/harness/allocate_task.cc with
  `-DCXXV_SYMBOLIC_FIELDS`) reported an invalid-pointer sentinel write in
  the young-space stack allocation once the initial stack length depended
  on the program. Cause: ESBMC loses the pointer's object through the bit
  mask of `HeapObject::_align` applied to a non-constant size (the write
  was aligned and in bounds; a reduced model shows the in-bounds
  assertion passing and the invalid-pointer check failing). The rounding
  in `Stack::allocation_size` was the identity and is removed (with a
  static_assert); both widths pass. The harness takes the expected
  length from `Stack::allocation_size` itself, so a wrong reservation
  size is not caught there (a one-word-short mutant passes); the stack
  length mutants are caught.
- Device memory (branch device/memory-pressure): the largest requests of
  an install-time verification above 1 KB are the heap check's copy of
  each byte-array literal (`ExecBody::Bytes`; the method-table literal, 4
  bytes per method), the converted literals (16 bytes each) and the object
  id table (2 KB). Bounding them needs a spec change (`ExecBody` and
  `VProgram::literals` in chunks).

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

Status of S1 (branch core/split-option, 2026-11-24, measure-2's R1-R3):
the split of S1 (call-speed-size) made the C6 4-50 % slower; it is now
the build option `split-loop` (Kconfig TOIT_VERIFIED_CORE_SPLIT_LOOP),
off by default on every ESP32 target: the whole loop (19.1 KB) fits the
classic ESP32's IRAM with 5.2 KB to spare and was faster there than the
split loop over four layout-perturbed builds each (PROGRESS.md). With the
option on, the hot part keeps the opcodes the device benchmarks execute
(PRIMITIVE, LOAD_SMI_U32, TRY/UNWIND, IDENTICAL, MOD, DIV, SHL, XOR,
INVOKE_STATIC_TAIL moved in) and calls `step_cold` directly (no request
in the machine). Open: on the classic ESP32 the flash layout moves single
benchmarks by up to 2x between builds that only shift the VM's flash code
by a few KB (f1 as much as f2); a placement that pins the hot flash
functions would make device numbers comparable across builds.

Status of S2-S6 (branch core/rpc-task-speed, 2026-11-24; artifacts
rpc-task-speed/README.md). C6, f2/f1 over three sessions: rpc-200 1.31 ->
1.14, yield-2k 1.24 -> 1.20, tasks-1k 1.43 -> 1.18; nothing else slower.
- S3: the finally records still move on a call or return in finally code
  (layout unchanged), but without `memmove` (`StackMem::move_records`,
  five words per step: the ROM memmove was ~130 cycles per record on the
  C6), and those calls and returns run first in `step::slow`, before the
  machine part (`slow_body`) whose entry saves most registers. Inlining
  them into the call handlers was 6 % faster on tasks-1k but grew the run
  loop by 6 KB (too much for the classic ESP32's IRAM); an out-of-line
  call from the handlers changed the loop's register allocation and was
  slower. Open: a layout in which a frame record does not displace the
  records (it changes `fins_rel` and the C++ stack copy).
- S4: `ensure_room_all` no longer runs after a primitive's return on the
  machine (top frame only, `step::top_room_kept`) nor after a TRY in
  finally code (`rnonlocal::try_fins` on the registers): 14 -> 6 full
  scans per ping-pong of tasks-1k. Left: one scan per task switch and per
  process entry (another stack, which the trusted contracts do not bound;
  a stored bound would extend them).
- S2/S6: the flash-resident helpers PC sampling found on the RPC and task
  paths are in the C6/S3 IRAM list (2.9 KB), the task transfer glue is
  V2_HOT. rpc-200 moves with the flash layout by 5-15 % in f1 and f2
  alike (FreeRTOS, scheduler and messaging run from flash; with
  CONFIG_FREERTOS_PLACE_FUNCTIONS_INTO_FLASH=n both get 7-8 % faster).
- S5: not done (0.5 % of an RPC on the host).

Status after branch core/rpc-task-speed-2 (2026-11-24; artifacts
rpc-task-speed-2/README.md):
- Where the finally-code cost comes from: every value-returning `monitor`
  method returns with a non-local return out of the block the compiler
  wraps it in (src/compiler/monitor.cc), through `__Monitor__.locked_`'s
  try/finally, so the finally code (resume_, yield checks) runs with a
  finally record and every call and return in it takes the slow path
  (48 per task ping-pong). An SDK change (compiler: the method's own
  returns exit the monitor block with the value; `locked_` returns it;
  `try-await_` leaves its loop with `break`; no try for an uncontended
  `locked_` or an empty message queue) removes them: f2 tasks-1k 350 ->
  278 ms, equal to f1 with the same change (274 ms; f1 before 301 ms).
  Not on this branch (artifacts sdk-monitor-nlr-v3.patch): it changes
  compiled code of every program and needs its own review.
- S3: the records layout is unchanged. Without the SDK change the slow
  round trip is 6.7 % of tasks-1k; with it the finally-code calls are
  gone from the benchmarks. Layouts weighed: finally records below the
  frame records (frames move on every record push and pop: more words
  moved than now, 20-35 frames deep); a gap between frame and finally
  records (the call fast path would need a second compare); records
  interleaved by frame (every frame index becomes a position lookup).
  Inlining the record-aware return into RETURN alone: tasks-1k -1.6 %,
  richards +0.5 %, run loop +274 B (not kept).
- S4: the scan is leaner (no per-frame bound check, 10 instead of 13 x86
  instructions per frame; tasks-1k -1.3 %). Removing it at a task switch
  without trust needs one of: (a) a bound on the arities of all methods,
  computed by the core once per run (the frames' arities at the measured
  switches were 3-9, the free words 120-200, so `rtop + bound +
  max_height + STACK_RESERVE <= top` would hold); it cannot live in the
  Machine (the run-entry theorems and the GC contracts take arbitrary
  machines) nor be linked to `env.p` by a type invariant (Env's fields
  are public), so the link `bound covers env.p.methods@` has to be a
  precondition of every function that takes the Env (about 190); (b)
  the save side: a spec lemma that every step keeps the body of every
  suspended Stack2 object but the running task's (prim_heap_ok already
  says so for primitives; heap_ext only keeps "is a Stack2"), so that a
  length recorded by the core when it suspends a task, with the room it
  had then, still holds at the switch back. Either is a proof change of
  its own; neither needs a trusted item.
- C++ primitive round trip (12 per ping-pong, 22 per RPC, 2 per yield):
  `cxx_primitive_v` saves 12 callee-saved registers on RISC-V; the C++
  side (`toit_v2_primitive`, `v2_primitive_failed`) is rendered for the
  C++ proofs (verified/cxx/annotated/ffi), so it was not changed here.
  It sets the yield floor (f2/f1 1.20, 1.28 with the SDK change).

Status after branch core/rpc-task-speed-3 (2026-11-25; artifacts
rpc-task-speed-3/README.md). C6, f2/f1 over three sessions: rpc-200
1.04 (1.01-1.04 over three layouts), rpc-echo-50 1.06, yield-2k 1.27 ->
1.17, tasks-1k 1.01 -> 0.95; richards 0.89 -> 0.90.
- C++ primitive round trip: `toit_v2_primitive` completes a plain
  failure itself (the retry protocol `v2_primitive_failed` only for the
  three errors that ask for a GC; VeriFast rendering updated, contracts
  unchanged). The PRIMITIVE handler calls the C++ primitive from the run
  loop (`rarrays::cxx_call`) and keeps no register across the call: after
  an unmoved call the registers are derived again from the Stack header
  and the top frame's record (`regs_reloaded`); kept across it, they took
  callee-saved registers in the whole loop and calls and returns reloaded
  the bytecodes' address (measured: +1-2 % on call-heavy benchmarks). A
  success or failure of a Rust port and of an unmoved C++ primitive share
  one completion (`complete_r`). Yield's floor: one round trip through
  `toit_v2_primitive` for `task_has_messages` and one for the transfer to
  the running task, which does nothing; an SDK change that skips the
  latter gives 1.12 (both formats faster; not on the branch). No Rust
  port is possible for the C++ primitives on these paths without a new
  trusted item (they need the message queue, the scheduler, the clock or
  the running task's identity).
- S4: no scan after a task switch in a run that switches often: a bound
  on all methods' arities (`room::Abound`, a local of `run_loop` passed
  to the PRIMITIVE handler; `abound_ok` in the four functions on that
  path) is computed by the core after four full scans in a run, and then
  `rtop + bound + max_height + STACK_RESERVE <= top` gives the room
  (`room_by_bound`). The save-side alternative (b) needs the stack's
  length, which the GC changes for suspended stacks and no contract
  states: not available without a trusted word. Left: the scans at
  process entry (two per service call), since the bound lives for one
  run.
- S3, S5: unchanged.

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

Status of V1/V2 (branch verifier/install-speed, 2026-11-24; artifacts
install-speed/README.md): done. The checker and the certificate decoder
build every map, successor and context in buffers kept for the whole
verification (109,498 -> 8,252 allocations per verification of hello
world), read single method fields from the record instead of decoding
whole headers, and the classic ESP32 builds the verifier at opt-level s
(+2.8 KB). On the rig board: 478 M -> 83 M instructions per install of
a 25 KB program, verification 4.1 s -> 0.67 s (25-37 KB programs:
0.67-0.94 s), install 5.9 s -> 2.6 s; the rest of an install is flash
erase and write. Proofs unchanged in substance (spec 994 -> 1,025
verified functions, THEOREMS.txt and the audit unchanged).

## 3. Spec requests from the refinement proof

For verified/spec/format/PHASE4-REQUESTS.md (not edited here: owned by
the spec work).

- R6 resource failures: done (spec `prim::resource_throw`, merged from
  spec/raise-and-resources); the core's ALLOCATE, double arithmetic and
  stack growth implement it.
- R7 traces of raised failures: done (spec `Outcome2::Raise`,
  `prim::raised`); the core's raise implements it (raise.rs).
