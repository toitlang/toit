<!--
Copyright (C) 2026 Toit contributors.

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; version
2.1 only.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

The license can be found in the file `LICENSE` in the top level
directory of this repository.
-->

# What the sandbox guarantees

This document states what is machine-checked about running an untrusted
Toit program on the verified interpreter, what that statement rests on,
what it does not cover, and the work that would remove its
qualifications. It is written for a reader who knows how claims like
those of seL4 or CompCert are worded, and it tries to be read the same
way: a theorem, its hypotheses, and its trusted computing base (TCB).

Every number is computed from the repository at commit `cab636881`
(2026-11-26) plus the commit that adds this document and
`verified/core/src/process.rs`. Where a number comes from a document
rather than from code, the document is named.

Contents:

1. [The claim](#1-the-claim)
2. [What the claim rests on](#2-what-the-claim-rests-on)
3. [What the claim does not cover](#3-what-the-claim-does-not-cover)
4. [Public wording at three strengths](#4-public-wording-at-three-strengths)
5. [Roadmap](#5-roadmap)
6. [Decisions for the owner](#6-decisions-for-the-owner)
7. [Discrepancies found while writing this](#7-discrepancies-found-while-writing-this)

## 1. The claim

### 1.1 The theorem in words

Let *P* be a program in bytecode format 2, installed or launched as an
untrusted container, so that the format-2 verifier ran on it under the
untrusted rules and accepted it with its certificate (at install time on
a device, with the verdict recorded under the current verification
epoch; at launch on a host). Let the VM be built with the verified core
(`TOIT_VERIFIED_CORE`). Then, under the contracts listed after the
clauses (and in section 2), for every run of the process, at either word
size (32 or 64 bits):

1. **Refinement.** At the start of every run (and, inside the run loop,
   after every instruction: the loop invariant, not an exported theorem) the interpreter's memory represents a state
   *s* of the formal format-2 semantics (`verified/spec/src/v2/spec.rs`)
   that the semantics reaches from *P*'s initial state by its own
   transitions and garbage collections.
2. **No undefined step.** *s* is well formed (`wf`), and the step from *s*
   is not stuck, nor is any completion of a primitive call or of a raised
   exception. "Stuck" is the spec's name for every situation a defensive
   interpreter would have to check at run time: an instruction outside
   the code or truncated, a stack slot outside the frame, a value of the
   wrong kind (not a small integer, object, instance, array, block),
   a field index out of range, a table index out of range, a call or
   branch target that is not a method or not in the code, a write to the
   read-only program heap, an arity mismatch, a malformed unwinding
   token, an allocation of a non-instance class, a fatal error
   (`Stuck` in `verified/spec/src/types.rs`). The defined failures
   (exceptions, out of memory, stack overflow, exit, uncaught exception,
   task end) are ordinary outcomes.
3. **The interpreter's own memory safety.** Every memory access the
   verified core makes while running *P* is in bounds of memory it holds
   a permission for, and the core has no undefined behaviour (Verus
   checks every function in `verus!` blocks for overflow, bounds and its
   contract; raw memory is read and written only through `vstd::raw_ptr`
   permissions).
4. **The machine's own objects.** The task objects' stack fields and ids,
   which the machine interprets and the program cannot read or write,
   keep the meaning the machine gives them (`machine_objects_ok`).
5. **No deep sleep, no reset.** An untrusted program cannot halt the
   device into deep sleep or reset it through bytecode (`accepts` with
   `trusted == false` rejects HALT 2 and 3).
6. **Only the primitives of its policy.** Every PRIMITIVE step of *P* names
   a primitive that the primitive table of its policy (the table the
   verdict was computed with, `PrimitivePolicy::verifier_arities`) allows
   with the frame's arity, denies or does not have; the core runs a
   primitive, its C++ entry or its Rust port, only if the table allows it,
   and completes a denied one with PERMISSION_DENIED and an absent one
   with PRIMITIVE_LOOKUP_FAILED without calling anything (since
   2026-11-26, branch verifier/single-pass).

Clauses 1, 2, 4 and 6 are one Verus theorem, `theorem_process`
(`verified/core/src/process.rs`, listed in `verified/THEOREMS.txt`;
clause 6 is its conclusion `prim_listed` together with the
preconditions `prim_allowed` of the core's only two ways to run a
primitive, `primitive::gc_call_primitive` and `prims::call`, which Verus
proves at every call).
Clause 3 is not a separate theorem: it is what Verus establishes for
every verified exec function, among them `step::run_loop`, whose contract
`theorem_process` uses. Clause 5 is part of `accepts`.

The hypotheses of the theorem are contracts of the code around the core:
the loader's (`theorem::loaded`), the scheduler's and collector's between
runs (`theorem::resumed`), and, inside `run_loop`'s proof, the leaf
contracts of the C++ calls a run makes (allocation, stack growth,
exception allocation, C++ primitives, each stated as an instance of a
spec transition). Section 2 lists them and what they rest on.

### 1.2 The statements, exactly

The definitions below are the Verus text, paraphrased only where the
paraphrase is a direct reading.

**`accepts(p, c, trusted)`** (`verified/spec/src/v2/verifier.rs`): the
abstract program `p` is well formed (`wf_program2`), its tables are
consistent with certificate `c` (`tables_ok`: certificate sizes, selector
representatives, dispatch entries, method table, interface-check
offsets, the builtin classes and entry points the machine uses), every
method satisfies the per-instruction rules against its stack maps
(`method_ok`), and the unchecked mode is used only if `trusted`.
On the device, `cert::verify_shipped` (a verified exec function, the
single-pass checker `v2::walk`) returns "accepted" only if some `c` with
the program's global count and the primitive table of its policy
satisfies `accepts(vview(p), c, trusted)`; `vview(p)` is the abstract view
of the tables vmverify read from VM memory. `accepts` takes a PRIMITIVE
only for a primitive that table lists (`prim_listed`: allowed with the
method's arity, denied, or absent).

**`loaded_ok(p, c, heap0, globals0)`** (`verified/spec/src/v2/sound.rs`):
the program heap is well formed (every object's class exists, instances
have their class's field count, contents are values, no suspended stack
or task objects, strings are valid UTF-8), it has fewer than 2^29
objects, the roots and literals are values of it, and the globals are
values. vmverify's `x_loaded_ok` decides exactly this (a verified exec
function).

**`wf(p, c, s)`** (`sound.rs`, the invariant of the soundness proof): the
heap is well formed (including suspended tasks, each of which satisfies
the task invariant at a `task_transfer`), the globals have the
certificate's count and are values, the roots and literals are values,
every frame's slots conform to the stack map at its current offset,
block references point to live block slots, handlers and finally
records are well formed, and the running task's stack field refers to a
stack object.

**`Machine::refines(p)`** (`verified/core/src/exec.rs`): the concrete
machine represents its ghost state `g`: the object-stack words are the
encodings of `g.stack` under the heap model's addresses, the frame and
handler records encode `g.frames`, `g.tries`, the finally records
`g.fins`, the globals are the encodings of `g.globals`, the heap model
(`heap_model_ok`: one distinct tagged address per object, class and body
agree) is `g.heap`, read-only objects are exactly those in the
program-heap address range, the program tables are related to the
abstract program (`prog_rel`), and the cached top-frame registers agree.
**`Machine::inv(p)`** is `refines(p) && accepts(ap, cert, trusted) &&
wf(ap, cert, g)`: the run loop's precondition.

**`advances(ap, g0, g1)`** (`verified/core/src/step.rs`): `g1 == g0` (the
instruction did not run: preemption, stack growth before a call), or
`g1` is what an outcome of `g0` continues in (`theorem::outcome`: the
step; a raise completed by `prim::raised`; a completed PRIMITIVE step,
i.e. any heap and result the primitive's contract allows; a resource
throw), or such a step with garbage collections (`gc::gc_steps`) before
and after it. **`reaches(ap, g0, g1)`** is the reflexive transitive
closure of `advances`.

**`gc_steps(ap, s, s2)`** (`verified/spec/src/v2/gc.rs`): any number of
collections. One collection may reset weak maps and null values of
their backing arrays (a superset of what the C++ weak processing does),
then renames the live objects to `0..n` (the live set contains the
state's roots and is closed under references) and drops the rest;
nothing else changes. Collections keep `wf` (`lemma_gc_steps_wf`).

**`run_post(p, m0, m1, r, e)`** (`step.rs`): if the run returns
preempted or yielded, `m1.inv(p)` and `reaches(ap, m0.g, m1.g)`
(`run_states`); and if it ended with a stuck report (`e` is
`RunEnd::Stuck(reason)`, the ghost third result of `run_loop`: the
reason the one `V2_REPORT_STUCK` call of a run passes), the result is
`(RESULT_TERMINATED, 1)` and `stop_ok(p, reason)`: the reason is the
resource limit `stuck::LIMIT`, or `stuck::FATAL` for a program heap
whose address range wraps around (`!ro_ok(p)`, checked before the first
instruction; the C++ loader never makes one). So a run never stops on a
stuck state of the spec (since 2026-11-26, branch prims/trust-round;
before, only `step_post` said so, roadmap item 5). The run loop
(`step::run_loop`, `requires old(m).inv(&env.p)`, `ensures
run_post(&env.p, *old(m), *final(m), (r.0, r.1), r.2@)`) is a verified
exec function; every other result ends the process (an exit of a step:
`RunEnd::Exit`). The theorems between runs use `run_states`.

**`theorem_soundness`** (`verified/spec/src/v2/theorem.rs`): if
`accepts(p, c, trusted)`, `!p.unchecked`, `loaded_ok(p, c, heap0,
globals0)` and `reachable(p, heap0, globals0, s)`, then the step from
`s` is not stuck, no completion of a PRIMITIVE step from `s` is stuck,
no outcome of `s` is stuck or an uncompleted raise,
`machine_objects_ok(p, s)`, and a PRIMITIVE step names a primitive the
certificate's table lists (`prim_listed`; the completions of a PRIMITIVE
include `prim_denied`, the PERMISSION_DENIED failure of a denied
primitive). `reachable` is a run of `transition`s
(outcomes that continue, within the memory bound `small`) **without
garbage collections**. `theorem_soundness_split` is the same for the
streaming checker's certificate representation; `lemma_split_complete`
shows that representation loses nothing.

**`theorem_first_run`, `theorem_next_run`** (`verified/core/src/theorem.rs`):
`loaded(p, m, heap0, globals0)` implies `m.inv(p)` and
`reaches(ap, initial_state, m.g)`; and if `m0.inv(p)`,
`reaches(ap, s0, m0.g)`, `run_post(p, m0, m1, r)` with `r` preempted or
yielded, and `resumed(p, m1, m2)`, then `m2.inv(p)` and
`reaches(ap, s0, m2.g)`.

**`theorem_process`** (`verified/core/src/process.rs`, added with this
document): for machines `ms[0..n]` (the start of each run), `es` and
`rs` (the end and result of each run) with
* `loaded(p, ms[0], heap0, globals0)`,
* for every run `i < n - 1`: `ms[i].inv(p) ==> run_states(p, ms[i], es[i], rs[i])`
  (the states part of `run_loop`'s contract `run_post`), `rs[i]`
  preempted or yielded, and
  `resumed(p, es[i], ms[i + 1])`,
* `!p.ap.unchecked` (implied by `accepts` for every untrusted program),

every `ms[i]` satisfies `inv(p)`, its state is reached from the initial
state (`reaches`), and that state has the five properties
`theorem_soundness` gives a reachable state. Since 2026-11-26 `loaded`
also says that the policy table the core reads (`Program::policy`) is the
certificate's primitive table (`policy_rel`), and `inv` carries it. Before this theorem, the
composition over any number of runs was stated only in prose
(theorem.rs: "for any number of runs and steps"), and
`theorem_soundness` covered only collection-free runs; the bridge is
`wf`, which `inv` carries and collections keep. The theorem adds no
trusted item; `process.rs` is deliberately not an input of the
verification epoch, so it does not invalidate installed verdicts.

### 1.3 What "confined" means today

What the theorem gives about what an untrusted program can reach:

* **Values and references.** Every value the program holds is a small
  integer or the id of an object of its own process' abstract heap
  (`good`); it cannot forge a reference, read or write outside an
  object's fields or elements, or jump outside its code. Everything it
  can name is its own state: its stack, its globals, its heap, the
  read-only program heap.
* **Read-only data.** Bytecode cannot write the program heap (the spec's
  stores fail on read-only objects; the core's verified writes require
  `!ro`), and since 2026-11-26 (branch prims/trust-round) neither can a
  primitive within its contract: `prim_heap_ok` keeps every read-only
  object unchanged and every object's `ro` flag. The 106 Rust ports are
  proved against it; for the C++ primitives it is part of their assumed
  contract (section 2.4, "Read-only objects").
* **Machine-owned state.** It cannot read or write a task's stack field
  or id, and no primitive may create stack or task objects or change
  the machine-owned fields (`prim_heap_ok`); the machine's own task
  primitives do that.
* **Calls out.** The only way out of the abstract machine is the
  PRIMITIVE instruction. The spec treats a primitive as an oracle: any
  result within its contract (`prim_spec`; the default contract
  `prim_default`: objects are only added, classes do not change, the
  machine's objects are not touched, read-only objects are not changed,
  every object stays well formed, the result is a value of the new heap,
  out-of-memory results are resource errors). The theorem holds whatever a primitive does within that
  contract.

* **Which primitives the program can call** (a theorem since 2026-11-26).
  The untrusted policy allows 150 primitives (141 of the core module, 2
  bitmap, the 4 timer and 3 events primitives; `src/primitive_policy.cc`,
  counted from `UNTRUSTED_CORE`, `UNTRUSTED_BITMAP` and the whole-module
  list). The verifier checks every PRIMITIVE against that table
  (`PrimitivePolicy::verifier_arities`: allowed with the method's arity,
  denied, or absent), the core gets the same table and runs a primitive
  only where it allows it (proven), and completes a denied one with
  PERMISSION_DENIED and an absent one with PRIMITIVE_LOOKUP_FAILED itself.
  Programs do contain calls of denied primitives (the core library's
  `print` tries `write_on_stdout` and falls back to the system process),
  so they are completed, not rejected. What remains trusted is that the
  table lists the policy as intended (one C++ function makes it from the
  lists above) and that index (m, i) names the C++ table's primitive at
  (m, i) (section 2.4).

What is enforced by code but **not** part of the theorem:
* **What primitives do outside the heap** (time, timers, events,
  messages): not in the spec at all.
* **Messaging and services.** The message-type and target gate, send
  grants, service-registration privilege and service opt-in
  (`src/scheduler.cc`, `src/process.cc`, `lib/system/services.toit`):
  enforced and tested; parts of the C++ (mailbox admission arithmetic,
  delivery authorization) are model-checked with bounds
  (`mailbox_room`, `mailbox_delivery`, `scheduler_delivery`,
  `process_send` in `verified/cxx/annotated/run.sh`); the policy as a
  whole is not a theorem.
* **Resource bounds.** Heap quota, mailbox and message quotas, timers,
  one process per group, 2 s of uninterrupted run time, the sandbox heap
  floor on the ESP32 (docs/sandbox-policy.md). Enforced and tested; not
  proved. The spec's only bound is `small` (sizes below 2^30), which the
  core meets by stopping with out of memory.

### 1.4 Attacker model

The attacker supplies the program image and its certificate (any bytes:
the install-time checks treat both as hostile), the program's own copy
of the core library (it is part of the image), every argument of every
primitive call it makes, and every message it sends. It does not control
the firmware, trusted containers or the system process, the device's
flash outside its image, or the hardware.

### 1.5 Platforms and word sizes

* Verus checks the spec and core crates for 64-bit words (x86-64 host)
  and for 32-bit words (`--target i686-unknown-linux-gnu`, the stand-in
  for the 32-bit devices), the core in both configurations of its run
  loop (`verified/check.sh` sections `verus`, `verus32`). Counts at this
  commit: spec 1090 verified (both widths), core 1092 (64-bit) and 1094
  (32-bit), core-split 1094 (64-bit) and 1096 (32-bit), 0 errors.
* The C++ proofs run for LP64 and ILP32 on Clang's AST of the host
  build (section 2.1).
* Devices with untrusted installs exercised: ESP32-C6 (RISC-V), classic
  ESP32 and ESP32-S3 (Xtensa) (docs/format2-migration.md). No proof is
  per instruction set; the target compilers are trusted.
* The default ESP-IDF configuration does **not** enable the verified
  core (`TOIT_VERIFIED_CORE` defaults to `n` in
  `toolchains/idf/components/toit/Kconfig`); such firmware refuses
  untrusted installs. The claim is about firmware built with it.

## 2. What the claim rests on

For each item: what would go wrong if it were false, how likely the
existing tests are to notice, and what would remove it.

### 2.1 Proof tools

| Item | If wrong | Evidence | Removal |
|---|---|---|---|
| Verus 0.2026.11.02 (VIR to SMT encoding, the mode checker, erasure) and vstd's axioms (`raw_ptr` `PointsTo`, `Seq`, `Map`) | a proof that does not hold; erased code that differs from the verified | `--no-cheating` cross-check of the escape-hatch audit; Verus' own test suite | accept as TCB (as seL4 accepts Isabelle) |
| Z3 (the solver Verus uses; also the IEEE binary64 checks of section `ieee`) | as above | none in this repository | accept |
| VeriFast (C) and its options `-fno-strict-aliasing -assume_left_to_right_evaluation` | a C++ proof that does not hold for the compiled code (C++11 leaves argument evaluation order unspecified; the VM is not built with `-fno-strict-aliasing`) | mutants (below); verified/CXX-ANNOTATED-PILOT.md argues each object word is accessed at one type | accept the tool; remove the options' gap by review rules or by porting the code |
| ESBMC, Frama-C/WP | bounded results only (below) | mutants for some jobs | accept the tools |
| The rendering tool `verified/tools/cxx_render.toit` (2609 lines, Toit, no proof) | the C that VeriFast proved is not what the C++ means | drift check (each sidecar's copy compared token by token with the source; committed renderings regenerated in the gate); 826 `static_assert`s on constants in 87 files, compiled for x86-64 and i686; 2 drift self-tests; 5 rule-refusal mutants; 367 mutant definitions in `run.sh` (353 must fail on both widths), each a reverted bug fix or a weakened check, last recorded fast-tier run "1413 checks ok, 0 FAIL" at 923316f3 (2026-11-25); one machine-code comparison (the finalizer unlink loop, Clang -O1, x86 only) | port the C++ to Rust (each port removes its rendering); an independent semantic check of the printer (compile rendered C and source C++ and compare behaviour on generated inputs) |
| What the AST is of | the C++ was rendered from Clang's AST of the **host** build (`-DTOIT_DEPLOY -DTOIT_VERIFIED_CORE`, x86-64 and i686); device `#ifdef` paths and the device compilers are not what was proved | device runs of the suites | render the device configuration too |

The gate (`verified/check.sh`) runs Verus (both widths), the audit, the
contract table, the layout table and the epoch on every change; with
`--tests` the C++ matrix's fast tier and the test batteries. The slow
tier (`--slow`) cannot pass today (section 2.6).

### 2.2 Compilers, runtime, hardware

| Item | If wrong | Evidence | Removal |
|---|---|---|---|
| rustc / LLVM for x86-64 and RISC-V | wrong code for verified Rust | none beyond tests (as for every Verus project) | accept |
| The Xtensa Rust fork (espup) | known wrong-code bugs (llvm#139, #140, #142, rust#278; verified/XTENSA-RUST-FIXES.md) | checked once, 2026-11-11, that our code does not trigger them (differential llc, assembly and IR scans, 15,000 QEMU verdicts); `verified/vmverify/tests/xtensa_codegen_check.sh` exists but no gate runs it | run the check in the gate on every change (small); accept the fork otherwise |
| GCC (ESP-IDF toolchains), Clang (host) for the C++ | wrong code for the C++ that the proofs assume or prove | tests | accept |
| ESP-IDF, FreeRTOS, drivers behind the allowed timer/event/clock primitives | memory corruption from below | tests, device soaks | accept as TCB |
| The chip (memory, MMU/flash mapping, no faults) | anything | none | accept; hardware faults are out of scope |

### 2.3 Trusted Rust (`verified/TRUSTED.toml`)

225 allowlisted items with 243 occurrences (each with a justification
and an exact count; unlisted occurrences fail the gate): core 129 items
(142 occurrences), spec 52 (52), vmverify 44 (49). There is no `assume`,
`admit`, `axiom` or `truncate`; two `external_body` proof functions are
axioms in effect (`view::inline_page_metadata`,
`step::trusted_field_accesses`, the latter only for the unchecked mode
of trusted programs).

| Crate | Kinds |
|---|---|
| core (129) | 42 `external_body`, 41 `plain_rust_item`, 34 `unsafe`, 7 `assume_new`, 2 `assume_specification`, 1 `plain_rust_file` (`machine.rs`, the checked loop, not built on devices), 1 `global_layout`, 1 `exec_allows_no_decreases_clause` (the run loop: no termination claimed) |
| spec (52) | 17 `plain_rust_file` (the reference interpreter, command-line tools, certificate inference and encoder for hosts), 12 `external_body` (9 in `xvec.rs`, 3 in format 1's `exec_step.rs`), 8 `unsafe` (`xvec.rs`), 7 `cfg`, 5 `plain_rust_item`, 3 `uninterp` |
| vmverify (44) | 12 `plain_rust_file` (among them `from_vm.rs`, the conversion from VM memory), 31 `unsafe`, 1 `cargo_metadata` |

What they amount to (verified/core/TRUSTED.md section 0 and 6):

* **Derivation points**: where VM memory becomes a permission
  (`Table::from_raw`, `Globals::from_raw`, `StackMem::from_stack`,
  `Heap::new`, `Runtime::allocation_window`, `inline_page_metadata`, and
  the views handed out after every call that may collect; 11
  `assume_new` occurrences in all). Assumed: the VM's memory is well
  formed now, with the values the heap model says, under one card-table
  bias for the whole run. If wrong: the core's in-bounds proofs are about
  memory that is not the object. Note that through vstd's `raw_ptr`
  axioms every assumed permission is also non-null, aligned and disjoint
  from every other live one; permissions that overlapped in reality
  (say, a program table inside program-heap storage) would make the
  ghost context inconsistent, so the proofs of the affected code would
  hold vacuously, not merely be wrong at one access. Tests: layout check,
  `TOIT_V2_VALIDATE` (weak: plausibility of stack slots, hosts only),
  ASan fuzzing.
* **The run loop's precondition at its call site**: `run_loop` is called
  from plain Rust (`machine::run`); `theorem_process` shows its
  precondition holds on every run given `loaded` and `resumed`, and
  those two are established by the trusted glue (the `assume_new`s of
  `toit_v2_run` and `machine::run`), not checked.
* **The FFI boundary**: the leaf contracts of `gc_allocate_instance`,
  `gc_allocate_double`, `gc_allocate_exception`, `gc_grow_stack`,
  `gc_call_primitive` and the allocator entries, each "the views
  represent a state that collections reach from the one before, with the
  spec's effect". Their C++ sides are partly proved (section 2.4); the
  contract table (`verified/CONTRACTS.toml`) is checked against both
  sides by the gate.
* **Loader** (`ffi::toit_v2_run`'s `Ghost::assume_new` of the abstract
  program, certificate and mode): the tables the core runs are the ones
  vmverify accepted. Rests on `from_vm.rs` (plain Rust), the binding of
  the verdict to the image (allocation checksum, epoch), and
  `prepare_process_v2` building the initial state.
  Not machine-checked either: that `from_vm.rs`'s object numbering is the
  one `Heap::new` and `prog_rel` use; that the context's `unchecked`
  field is 0 for untrusted processes; that the context's policy table is
  the one the verdict was computed with (`policy_rel` in `loaded`; until
  2026-11-26 the trusted fact here was that `core_arities` agrees with
  the policy, on which confinement rested: a denied primitive must not
  run as its Rust port; now the proof shows that no primitive runs unless
  the verified table allows it).
* **Between runs** (`machine::run`'s `assume_new` of the ghost state): the
  scheduler resumes the state it saved, after collections, and nothing
  but collections touches a suspended process' state.
* **Configuration**: Verus checks the core with the features
  `checked-loop`, `layout-tables` and `preempt-a-lot`; device builds leave
  them out (which only removes code). The layout check runs on host
  builds only; device constants rely on the i686 check and on both sides
  following the target's C ABI.
* **The verification epoch** (installed verdicts are valid only under the
  epoch that computed them) hashes the spec crate, vmverify, the core's
  `theorem.rs`, `ffi.rs`, `abs.rs` (`prog_rel`), `exec.rs` (`refines`,
  `inv`, `policy_rel`), `view.rs` and `layout.rs`, the C++ install-time
  checks, `src/interpreter_v2.cc` (the context the core gets) and
  `src/primitive_policy.*` (the policies' verifier tables); since
  2026-11-26 (roadmap item 6a).
* **Not memory**: preemption watermark, floating point (`prims/fp.rs`,
  the spec's uninterpreted float functions), the word size, pointer
  arithmetic provenance (`assume_specification` of `wrapping_add`,
  `wrapping_offset`), one aligned 16-bit load.
* **Trusted programs**: `Accepted::trusted_program` lets trusted
  (first-party) programs run on the same core without verification on
  devices (`V2MethodTable::trusted_on_verified_loop`). A miscompiled
  trusted program can corrupt the VM, including untrusted processes'
  memory: **trusted containers and the system program are in the TCB.**

### 2.4 C++ that the claim assumes

The core's leaf contracts make the following C++ part of the TCB unless
proved. Status from `verified/cxx/annotated/README.md` and
`verified/CONTRACTS.toml`; counts checked by the gate's `contracts`
section at this commit.

| Component | Proved | Assumed or only tested |
|---|---|---|
| Collector | VeriFast (unbounded, both widths): marking, scavenging, root processing, object moves, stack relocation, mark bits; Frama-C/WP: page scan; many ESBMC fixtures (bounded) | **that a collection is `gc_steps`**: root completeness, preservation of the reachable graph, all live references registered; the assumptions `gc_equiv_trans`, `stack_copy_equiv`, `gc_owns`; the heap and stack bridges of CONTRACTS.toml. A Rust young-generation copy was proved in a pilot (`gcbridge::lemma_collected`); the plan is a Rust+Verus collector |
| Allocator | VeriFast: semispace, young allocation, free lists, remembered cards, limits; ESBMC fixtures | raw space and its relation to the abstract heap (establishing `heap_model_ok`), address-to-metadata mapping, OS page providers, contract-only `allocate_instance`, `allocate_double`, `allocate_large_integer` |
| Scheduler | VeriFast: ready queue, workers, targets; ESBMC (bounded): GC barrier, delivery, teardown, spawn, notify, timer dispatch | `resumed` as a whole; notifier locking and lifetime; locks and the OS modelled at call boundaries |
| Messages | VeriFast: encoder, decoder, receive ownership, sender | 7 decoder assumptions (`ipc_begin`, `ipc_room`, `ipc_pointer`, `ipc_external`, `ipc_length`, `ipc_end`, `gc_owns`), `two_pass_room` (encoder), the encoders of `process_send` and spawn |
| Install-time checks | VeriFast: `builtin_classes_error`, `has_valid_error_roots`; ESBMC: image checks part 2 (both widths), part 1 (`image_layout_error`) on ILP32 only; Frama-C/WP: the record validation loop; Verus: the whole verifier (`cert::verify_shipped` accepts only if `accepts` holds: the single-pass `v2::walk`; `x_loaded_ok == loaded_ok`) | `builtin_roots_error` (no verdict in 30 min); `image_layout_error` on LP64 (no verdict); that every untrusted process runs a table that passed `v2_verify` (reviewed) |
| FFI glue | VeriFast: `interpreter_v2` glue; ESBMC: core entry (bounded) | `gc_allocate_exception` and the exception encoder (not rendered) |
| Primitives (150 in the untrusted set) | 106 are ported to Rust and proved in Verus against `prim_spec`; of their C++ fallbacks, 62 are proved with VeriFast and 34 are proved unreachable from untrusted code; of the 44 primitives that stay in C++, 33 are VeriFast-proved and 11 have bounded ESBMC body checks | 10 reachable contract-only fallbacks (`blob_equals`, `blob_index_of`, `byte_array_at`, `byte_array_length`, `compare_simple_json_string`, `list_add`, `number_to_integer`, `size_of_json_number`, `smi_multiply`, `string_rune_count`); open parts of proved ones (`process_send`'s graph correspondence, byte preservation in three string conversions) |
| Read-only objects (`prim_heap_ok` keeps them, since 2026-11-26) | the 106 Rust ports (Verus: every heap update of a port goes through `prims::lemma_post_update`/`lemma_post_content`/`array::lemma_post_set_*`, which require a mutable object, and a writable content view is of a mutable object, `view::content_ok`); write-site facts of the VeriFast proofs: the destination of `byte_zap`, `blit`, `byte_array_replace`, `string_write_to_byte_array`, `put_uint_big_endian`, `put_uint_little_endian`, `put_float_32_little_endian` and `put_float_64_little_endian` comes from the proved `mutable_byte_content` (`mutable_result`: outside the program heap, also the copy-on-write wrapper it switches to its copy), `byte_array_at_put` asserts it at the write (a mutant leaves the check out), `add_finalizer`/`remove_finalizer` leave program-heap keys alone | an assumption for every C++ primitive: VeriFast's heap model abstracts byte contents (`uchars(.., _)`) and owns program-heap objects like any other, so no C++ proof states "the program heap is unchanged" as a postcondition; the write-site facts cover the writes those proofs show, and the other proved C++ bodies write no existing object (they read and allocate). Without a write-site proof: `process_send` (neuters only byte arrays with an active finalizer, which no program-heap object has: the loader refuses the flag, `add_finalizer` refuses program-heap keys), `timer.delete` and the events primitives (resource proxies only, which an image cannot contain: `from_vm.rs` refuses external byte arrays not tagged RawByteTag), `task_new`/`task_transfer` (machine-completed: `task_step`, not the primitive contract). Hardening tests: `tests/sandbox/cli/program-heap-write-main.toit` (every writer aimed at program-heap bytes and string literals: refused, unchanged) |
| Retry rule (a primitive that ran out of memory, a GC, the retry: one completion) | 77 of the 150 by VeriFast (`oom_clean`, `oom_unchanged`) | 62 by a textual check ("cannot fail for want of memory", not a proof), 9 by test only, 2 by review; the composition itself is the assumption `prim_retry` |
| The policy table | contract table checks it covers the same 150 primitives as the retry classification; since 2026-11-26 the core runs a primitive only where the verifier table of the policy allows it (proven) | `PrimitivePolicy::verifier_arities` lists the policy as intended (made by one function from `UNTRUSTED_CORE`, `UNTRUSTED_BITMAP` and the whole modules); index (m, i) names the C++ table's primitive at (m, i) (`PrimitivePolicy::at`, `build_partial_table`: an allowed entry is the VM's own); reviewed and tested |

### 2.5 Assumptions and trusted specifications

* `[[assumption]]` entries in `verified/CONTRACTS.toml`: 11
  (`two_pass_room`, `gc_equiv_trans`, `stack_copy_equiv`, `prim_retry`,
  the six `ipc_*`, `gc_owns`), each checked to be bodiless with exactly
  the listed contract; the gate fails on an unlisted bodiless lemma.
* Bridges: `stack`, `primitive`, `heap` (CONTRACTS.toml, "the remaining
  reviewed assumption of the seam"); not checked by a tool.
* Trusted VeriFast specifications (README, "What remains trusted in the
  C++"): libc `memcpy`/`memmove`/`memset`, libm (`fmod`, `sqrt`, `ceil`,
  `floor`, `trunc`, `round`; mostly `requires true; ensures true`),
  `localtime_r`, `mktime`, `strtod`, `snprintf` and Dragonbox, OS clocks
  and entropy, `bit_cast` instances, the 23 builtin class-id getters
  (checked against their slots by ESBMC on both widths), `classes_agree`,
  the allocator's contracts, the write barrier, the policy table, the
  mailbox and argument-slot model, 7 function bodies marked `trusted`.

### 2.6 Bounded checks and checks without a verdict

* Every ESBMC job is bounded (`--unwind` 2 to 65); structural fixtures
  are small (a few list nodes, a few table entries). They show the
  absence of bugs up to the bound, not in general.
* Five jobs have no verdict, all on LP64 (`known_noverdict` in
  `verified/cxx/annotated/model-check-jobs.sh`): `gc-compaction-overhang`,
  `gc-metadata-layout`, `free-list-selection`, `install-image-layout`,
  and the mutant `gc-sweep-chunk-uncounted`. The results that cite them
  hold for 32-bit words only, which is the width of every device; on the
  64-bit host they are unchecked. Because `run.sh --slow` reports them
  as NOVERDICT, `check.sh --slow` cannot pass while they exist, and the
  default gate runs only the fast tier, so the 22 ILP32 slow-tier jobs
  are not rechecked on every change.
* No verdict either: `builtin_roots_error`, the mutant
  `install-image-classes-range`.

### 2.7 The specification

* **Is "not stuck" what a user cares about?** It is the absence of
  every undefined behaviour of the abstract machine, plus memory safety
  of the interpreter. It is the property a sandbox needs from its
  interpreter (no escape through the interpreter), not functional
  correctness of the program or of its library.
* **The spec matches the Toit language** only as far as the
  differential tests show (`verified/spec/tests`, the untrusted suite);
  a divergence would be a functional bug, not a hole, unless it lets a
  program reach a state the C++ treats differently.
* **Weak maps.** A collection may reset any weak-capable map and null
  values of its backing (a superset of the collector's behaviour); the
  claim holds for any such choice.
* **Primitives are an oracle.** The theorem is "the interpreter is safe
  whatever the primitives do within their contract"; the contract says
  nothing about effects outside the heap. Since 2026-11-26 it keeps the
  read-only objects (`prim_heap_ok`); before, it kept classes and machine
  objects but not the contents of the program heap. The theorem's
  quantification over a PRIMITIVE's completions narrowed accordingly: a
  completion that changes a read-only object is no longer among them,
  which for a C++ primitive is an assumption (section 2.4).
* **The bridge to real memory** is `refines`, with the heap model
  (`heap_model_ok`, `view::word_val`, the layout facts) tied to the C++
  object layout by `verified/LAYOUT.toml` and `layout_check.cc` (host
  builds only; 170 entries). That the C++ allocator and collector
  maintain the heap model is assumed (2.4). Separation from other
  processes' memory follows only from these assumptions: the abstract
  heap is per process, and the permissions the core gets are assumed to
  cover exactly that process' objects.

## 3. What the claim does not cover

* **Availability.** A run may end in out of memory, stack overflow or
  the run loop's implementation limit; the scheduler may kill a process
  after its run-time limit. The run loop is not proved to terminate
  (preemption is the C++ scheduler's). Denial of service of the system,
  of other containers or of services is mitigated by quotas and the heap
  floor, not proved; known gaps are listed in docs/sandbox-policy.md
  (console flood, mailbox quota scope, native allocations not charged,
  the system process restarting the device on some of its own
  allocation failures, no watchdog on the classic ESP32).
* **Side channels.** Timing, allocation and counting channels are not
  addressed (docs/sandbox-policy.md lists them as accepted).
* **Confidentiality and integrity between processes** as a theorem
  (noninterference). They follow from memory safety only under the
  assumptions of section 2.
* **What primitives and services do**: their correctness, their effects
  on devices, files, network, other processes.
* **Trusted code**: the system process and trusted containers are not
  verified and run with full privilege.
* **Hardware faults** (bit flips, glitching, power), and attacks on the
  flash outside the image.
* **Builds without the verified core** (firmware built without
  `TOIT_VERIFIED_CORE`, host builds where cargo was missing: they build
  without the core with a warning) run no untrusted program, so there is
  nothing for the claim to cover: they refuse every untrusted container,
  format 1 with `FORMAT_2_REQUIRED` and format 2 because they can neither
  verify nor run it. No build runs an untrusted format-1 program: install,
  spawn and launch refuse it with `FORMAT_2_REQUIRED`. (The flag
  `-Xuntrusted_format1` and the variable `TOIT_UNTRUSTED_FORMAT1=1`, which
  ran such programs on the unverified C++ interpreter, were removed; the
  negative tests are `tests/sandbox/cli/format1-*-snapshot` and
  `tests/sandbox/boot-refused-test.toit`.)
* **Functional correctness** of the program's execution with respect to
  the Toit language.

## 4. Public wording at three strengths

How others word such claims (from the cited papers; paraphrased, not
quoted): seL4 (Klein et al., SOSP 2009; Klein et al., ACM TOCS 2014)
states functional correctness of the C code against an abstract
specification and lists as assumptions the compiler (later removed for
ARM by translation validation, Sewell, Myreen, Klein, PLDI 2013), the
assembly and boot code, cache and TLB management, and the hardware; its
information-flow proof (Murray et al., IEEE S&P 2013) excludes timing
channels explicitly. CompCert (Leroy, CACM 2009) proves semantic
preservation for source programs without undefined behaviour and names
the unverified parts (front-end preprocessing, assembler, linker; Coq's
extraction and the OCaml compiler); Yang et al. (PLDI 2011) found bugs
only in its unverified parts. CakeML (Tan et al., JFP 2019) allows the
compiled program to stop early with out of memory, and models foreign
calls as an oracle, as our primitives are. vWasm (Bosamiya, Lim, Parno,
USENIX Security 2022) proves a safety property, not functional
correctness: compiled code cannot access memory outside its sandbox;
its TCB includes F* and the assembler. Verified bytecode verifiers
(Klein and Nipkow, TCS 2003) state "well-typed programs do not go wrong"
against a defensive VM model. The common pattern: name the property,
name the model it is relative to, list every assumption.

**(i) Today.**

> Untrusted Toit programs in bytecode format 2 are checked at install
> time by a verifier whose soundness is machine-checked in Verus. For
> every program it accepts, it is machine-checked that the Rust
> interpreter only performs steps of the formal bytecode semantics, that
> no step is undefined (no type confusion, out-of-bounds access, forged
> reference, invalid jump, or bytecode write to read-only program data),
> and that
> the interpreter's own memory accesses are in bounds, for 32- and
> 64-bit words. This holds under stated contracts of the C++ runtime it
> calls (garbage collector, allocator, scheduler, program loader and the
> C++ primitives), which are proved only in part, and assumes the proof
> tools, compilers, operating system and hardware, and the firmware's
> own trusted programs. It is also machine-checked that the program can
> call only the primitives its policy allows (relative to the policy's
> table, which the firmware computes from the policy). Its memory,
> message and time quotas are enforced and tested but not proved.
> Availability and side channels are not covered.

**(ii) After the finite list of section 5: items 1 to 10, 12 and 13.**

> ... it is machine-checked that the interpreter only performs steps of
> the formal bytecode semantics, that no step is undefined, that its
> memory accesses are in bounds, and that the program can call only the
> primitives of its policy, each of which is proved against its contract
> for the program's heap. The remaining assumptions are the contracts of
> the garbage collector, the allocator and the scheduler's resumption of
> a process, the firmware's own trusted programs, the proof tools (Verus,
> Z3, VeriFast), the compilers (rustc and the Xtensa fork, GCC), ESP-IDF
> and the hardware. Quotas are enforced and tested; availability and side channels are not covered.

**(iii) Aspirational.**

> For every program the verifier accepts, the device's execution of it is
> a run of the formal semantics, and the program's effects are confined
> to its own memory and to the primitives and services of its policy,
> whose effects are specified and proved; the trusted base is the proof
> tools, the compilers and the hardware.

That needs the collector and allocator in verified Rust (item 11), the
loader conversion proved (item 9), a confinement statement that includes
the policy and the primitives' effects outside the heap, resource bounds
as theorems, and an ESP-IDF boundary that is either specified or
accepted by name. Noninterference between processes and timing would be
further steps beyond (iii).

## 5. Roadmap

Ordered by how much weaker the claim is than it could be, relative to
the effort. Sizes: small (hours to a day), days, weeks.

| # | Item | Buys in the wording | Size | Depends on | Kind |
|---|---|---|---|---|---|
| 1 | Done: `-Xuntrusted_format1` / `TOIT_UNTRUSTED_FORMAT1` removed from every build (untrusted format-1 programs are refused at install, spawn and launch); a build without the core refuses every untrusted program (it still builds, with a warning, when cargo is missing) | drops "unless configured otherwise" | small | – | code removal |
| 2 | Decide whether the verified core is the default for device firmware (`TOIT_VERIFIED_CORE`) | the claim applies to the shipped firmware, not a variant | small (decision), size issue on classic ESP32 | none | decision |
| 3 | ~~Check the allowed primitive set in the verifier~~ **Done 2026-11-26** (branch verifier/single-pass): `accepts` checks every PRIMITIVE against the policy's table (allowed with the arity, denied or absent: programs contain denied calls by design, so they are completed with PERMISSION_DENIED or PRIMITIVE_LOOKUP_FAILED by the core, not rejected); the core runs a primitive only where the table allows it (`prim_allowed` required by `gc_call_primitive` and `prims::call`) | "can call only the primitives of its policy" is a theorem; the `core_arities` trust is gone (replaced by `policy_rel`: the core gets the table the verdict was computed with) | days | new epoch | proof, verifier change |
| 4 | ~~Strengthen `prim_heap_ok`: read-only objects and the `ro` flag unchanged~~ **Done 2026-11-26** (branch prims/trust-round): `prim_heap_ok` keeps every read-only object and every `ro` flag; the 106 Rust ports are proved against it, for the C++ primitives it is part of the assumed contract (section 2.4); hardening tests of the refusal. Not exported as a run-level theorem: that needs the program heap as a fixed prefix of read-only objects referring only to read-only objects (an invariant `refines` and `loaded` do not carry yet) to cross collections, and suspended stacks and tasks known to be mutable for `task_step` | "never modifies read-only program data" holds for primitives within their contract (C++ primitives assumed, Rust ports proved) | small | new epoch (taken on the branch) | spec change |
| 5 | ~~Export what `step_post` already proves into `run_post`: a run never stops on a spec-stuck state, only on the resource limit~~ **Done 2026-11-26** (branch prims/trust-round): `run_loop` returns a ghost `RunEnd` (an exit of a step, or the reason of its one stuck report) and `run_post` says a stuck report is `stuck::LIMIT`, or `stuck::FATAL` before the first instruction for a program heap whose address range wraps (`stop_ok`); what remains is that wrap check, which the C++ loader's allocation never triggers | the theorem says the defensive checks never fire, not only that every reported state is fine | small | `run_loop` change | proof |
| 6 | The 10 reachable contract-only fallbacks, the 9 test-only and 2 review-only retry rules | "every primitive an untrusted program can reach is proved against its contract" | days to weeks | none | proof, or code removal (port to Rust, or make the fallback unreachable) |
| 6a | ~~Make the epoch's inputs the whole contract the core assumes~~ **Done 2026-11-26**: `abs.rs`, `exec.rs`, `view.rs`, `layout.rs`, `src/interpreter_v2.cc` and `src/primitive_policy.*` are inputs | "a verdict is used only by the checks and contract that computed it" without a manual step | small | one epoch change | gate |
| 6b | Run the layout check on device builds (or generate the device constants from the target headers) | removes "device layout from the i686 check" | days | device toolchains in the gate | gate |
| 7 | Run the Xtensa code-generation check in the gate; record its rules (FFI of at most 6 words, no over-aligned locals) in TRUSTED.md | the Xtensa compiler item from "checked once" to "checked on every change" | small | toolchain in the gate machine | gate |
| 8 | Close the install-time checks: prove `builtin_roots_error`; get a verdict for `install-image-layout` on LP64 or move the layout check into vmverify (Verus) | "the install-time checks are proved" without word-size qualification | days | none | proof; a format change could make the layout check part of the Rust verifier and remove the C++ check |
| 9 | Prove the loader conversion `from_vm.rs` and the binding of the initial state | the loader contract from trusted to proved, except the flash binding | weeks | none | proof; a format change that lets the verifier read the very tables the core runs (one representation, read through the same views) removes the conversion |
| 10 | Rendering trust: record mutant verdicts at every gate run; render the device configuration; extend the machine-code comparison; reduce `-assume_left_to_right_evaluation` dependence | the C++ proofs mean what they say for device builds | days | none | gate, proof hygiene |
| 11 | The collector and allocator in Rust and Verus, delivering `gc_steps` and establishing `heap_model_ok` | removes `gc_equiv_trans`, `stack_copy_equiv`, `gc_owns`, the heap and stack bridges, the GC part of `resumed`, the derivation points after collections | weeks to months | the pilot (`gcbridge`) | redesign |
| 12 | IPC: prove the 7 decoder assumptions and `two_pass_room`, or a message format that a single-pass encoder and a self-bounding decoder handle | removes 8 of the 11 assumptions | weeks | none | proof, or a new message format |
| 13 | The 5 no-verdict LP64 jobs and the ILP32 slow tier in a regular run | removes "for 32-bit words only" from the host statement | days (restructure fixtures) | none | proof engineering |
| 14 | Resource bounds as theorems (heap quota, mailbox, run time) | moves quotas from "enforced and tested" to "proved" | weeks | 11 for the heap | proof |

## 6. Decisions for the owner

* Which items are permanent assumptions, named in the public claim:
  Verus and Z3, VeriFast, rustc and the Xtensa fork, GCC, ESP-IDF and
  FreeRTOS, the hardware. (seL4 and CompCert name theirs the same way.)
* Whether the collector stays "trusted GC-class code" (claim (ii)) or is
  rewritten in Verus first (claim (iii)).
* Whether to accept the new verification epoch of item 4 (branch
  prims/trust-round changes the spec crate and `view.rs`, both epoch
  inputs; item 3 took one on 2026-11-26, approved; every installed
  untrusted container must be reinstalled).
* Whether to make the verified core the device default (item 2; the
  format-1 untrusted path of item 1 is removed), and whether a host build
  that finds no cargo should fail instead of building without the core
  (such a build refuses every untrusted program either way).
* Whether to change the bytecode, certificate or message format where
  section 5 says it would remove an item (8, 9, 12).
* Whether trusted containers running unverified on the same core are
  acceptable in the TCB, or whether trusted programs should be verified
  at launch too (they can be: debug builds do).

## 7. Discrepancies found while writing this

Between prose and theorems:

1. `verified/core/src/theorem.rs` (module comment): "`run_post` says the
   loop never reports a stuck state of the spec and never takes a fatal
   path". `run_post` constrains only preempted and yielded results. The
   step-level contract (`step_post`) does restrict stuck results to the
   resource limit, but that is not exported, and `run_loop` has a fatal
   path (a program-heap range that wraps). Fixed 2026-11-26 (branch
   prims/trust-round, roadmap item 5): `run_post` now says it, with the
   wrap check as the one other stuck report, and the comment says so.
2. The same comment says the composition holds "for any number of runs
   and steps" without a theorem; now `theorem_process`.
3. `verified/spec/SOUNDNESS.md` showed the theorem without the
   hypothesis `!p.unchecked`, described `reachable` without saying that
   it excludes collections, and gave two conflicting stale counts.
   Fixed.
4. `docs/sandbox-policy.md`, "Known gaps": "the interpreter is proven
   to follow it" without the leaf contracts; "Nothing has run on real
   hardware yet" and "host-only" are stale. Fixed.
5. `verified/core/src/ffi.rs` (`Accepted::trusted_program`): "A wrong
   program can crash the VM, it cannot reach an untrusted process". A
   miscompiled trusted program that corrupts memory can affect untrusted
   processes; the token only keeps untrusted processes off the trusted
   path. Not changed (an epoch input); recorded here and in 2.3.
6. `verified/core/TRUSTED.md` and `DESIGN.md` name
   `toit_v2_lookup_primitive` and `toit_v2_call_primitive`, which are now
   one entry, `toit_v2_primitive`. Fixed in TRUSTED.md section 8; the
   DESIGN.md table and `spec/src/v2/prim.rs` (an epoch input) still use
   the old names.
7. `verified/core/OBLIGATIONS.md`: "106 of the 143 allowed" leaves out
   the 7 timer and events primitives (150), and "remaining 37" is 44.
   Fixed (DESIGN.md's "143 allowed, 37 in C++" is not changed).
8. `verified/core/OBLIGATIONS.md` section 1 and `verified/core/DESIGN.md`
   section 9 repeated the overstatement of item 1, and DESIGN.md said
   that Verus checking every precondition gives the result "for any
   number of runs": `run_loop` is called from plain Rust, so its
   precondition on every run is the theorems plus the trusted glue.
   Fixed.
9. `verified/core/TRUSTED.md` section 0 says no accessor of VM memory is
   trusted and section 1 that the derivation points are the only places
   permissions arise; `Runtime::allocation_window` and
   `inline_page_metadata` are permission sources too (listed under "Not
   memory"), and the aligned load, the checked loop's raw accessors and
   the preemption word are trusted accessors. Not changed.
10. `verified/verification-epoch.cmake` says its inputs define "what the
   verified core assumes of an accepted program"; `prog_rel`, `refines`
   and the views are not inputs (section 2.3). Not changed (roadmap 6a).
11. `verified/TRUSTED.toml`'s header says it lists the core and spec
   crates; it also lists 44 vmverify items. `verified/vmverify/README.md`
   ("What is trusted") omits `device.rs` and `lib.rs`. Not changed.

Between documents (not changed here; see the reports of this review):
`verified/cxx/annotated/README.md` has stale counts (constants checks,
proof runs, the decoder's assumptions), says "unbounded" in its
introduction while many parts are bounded, and discusses 3 of the 5
no-verdict jobs; docs/format2-migration.md describes 16-byte method
records (`TMT1`) where the code has 4-byte records (`TMT2`); round 4 of
the red team lists F-TIMEINFO as open while the primitive audit lists it
as fixed and proved; the round-2 battery is stale and not in the gate.
