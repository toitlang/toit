# 19. Loop and map built-ins (proposal, not decided)

Branch `proposal/builtins` (from `sandbox-integration` a3aa3a78). Not to
be merged without the owner's decision; each built-in can be taken or
left on its own (the two loop steps share their verifier rule and proofs;
HASH_FIND is independent of them). Raw numbers,
scripts and test programs: /home/flo/work/opentoit-sandbox-artifacts/
builtins/ (`ir.sh`, `snaps.sh`, `wall.sh`, `devsize.sh`, `t/`).

## Question

Note 11 removed the four format-1 intrinsics (re-entrant state machines
that call blocks and restart); note 16 recommended bringing `HASH_FIND`
back as a non-reentrant built-in and deciding a `REPEAT` instruction by
measurement. With the register loop the verified core is at 1.13 / 1.40 /
1.17 times the C++ interpreter's instructions on richards / deltablue /
pystone, but a `repeat` loop costs 1.4x C++, `List.do` 1.4x and map
lookups 1.06-1.34x (and 1.5-2x before the register loop). Should format 2 get
built-ins for them, and in which shape, given the proof cost?

## Design rule

No built-in calls Toit code, keeps state outside the frame, or writes the
heap. Each is one bounded step whose loop stays in the bytecode, so the
verifier's ordinary rules cover the loop; a built-in either does its fast
step or falls through to the ordinary Toit code, which re-checks
everything (the semantics of a program never depend on the fast path
applying). All read program-controlled fields only through the checked
accessors the core already has (INVOKE_SIZE's and INVOKE_AT's fast paths,
the heap view), and are total for any heap.

The compiler emits them only in format 2, only inside the core library
methods that carried format-1 intrinsics (`SmallInteger_.repeat`,
`SmallArray_.do_`, `HashedInsertionOrderedCollection_.find-body_`),
through the existing format-2 lowering of `#primitive.intrinsics.*`
(`ByteGen::generate_intrinsic_v2`). The core library is unchanged, and
format 1 compiles to the same programs as before (checked: 12 programs,
the benchmarks, the test programs below and five suite tests, identical
program dumps; only the embedded SDK version string differs,
`f1-identity.sh`). `-Xv2_builtins=MASK` / `TOIT_V2_BUILTINS=MASK` (bit 0
REPEAT, 1 ARRAY_DO, 2 HASH_FIND, default all) selects them, which is how
the numbers below compare the built-ins one by one on the same VM.

## The built-ins

### LOOP_REPEAT (101, 4 bytes: `back:u16 n:u8`)

Slot `n` is the counter, `n + 1` the block, `n + 2` the limit (counted
from the top before the step). The step pops the top (the previous block
result); if counter and limit are smis with counter < limit, it stores
counter + 1, pushes a copy of the block and the old counter and branches
back by `back` (to the INVOKE_BLOCK); otherwise it falls through.
`repeat` becomes

```
  LOAD_SMI_0; LOAD_NULL; BRANCH test
body:  INVOKE_BLOCK 2
test:  LOOP_REPEAT body S1
       <the ordinary counter loop of note 11, which returns at once>
```

so an iteration is INVOKE_BLOCK + LOOP_REPEAT (2 dispatches instead of
14; format 1: one intrinsic re-dispatch). Preemption: every iteration
calls the block, and the call checks the watermark.

### LOOP_ARRAY (102, 4 bytes: `back:u16 n:u8`)

Counter `n`, block `n + 1`, end `n + 2`, array `n + 3`. As LOOP_REPEAT,
with the fast condition "counter and end are smis, 0 <= counter < end, the
array slot holds an `Array` with more than counter elements" and the
element pushed instead of the counter. In `SmallArray_.do_`, which
`List.do` (`array_.do_ size_`) and `LargeArray_.do_` (per arraylet) call.
Plain arrays only, as the C++ intrinsic; anything else (a large array
passed directly, an end beyond the array) falls through to the ordinary
loop, which does what format 2 does today (INVOKE_AT, OUT_OF_BOUNDS).

### HASH_FIND (103, 5 bytes: `miss:u16 n:u8 m:u8`)

One probe of the index of a hashed collection: the loop of `find-body_`
up to the first point where Toit code must run. The probe state is in
slots `n` (slot), `n + 1` (triangular step, 0: start at `hash & mask`)
and `n + 2` (first deleted slot + 1, 0: none), the hash in slot `m`, the
collection in slot `m + 2`. It reads `index_` and `backing_` (fields 2
and 3) and walks the index with the Toit loop's probe order, tombstone
rule and full-index test, at most twice the index size probes:

* a key whose stored hash bits match and that is not a tombstone: stores
  the probe state, pushes the key and its backing position, falls
  through. The bytecode calls the `compare` block exactly as the Toit
  loop does (equality stays Toit: `compare_` is overridable, e.g.
  `IdentityMap`, and the machine cannot know it) and on false loops back
  to HASH_FIND, which continues from the stored state;
* otherwise it pushes a code and branches forward: `2 * slot + 1` (a free
  slot, no deleted one on the way), `2 * slot` (reuse the first deleted
  slot), -1 (index full: rebuild) or -2 (irregular: anything the fast
  paths of INVOKE_SIZE/INVOKE_AT do not handle, a non-power-of-two or
  huge index, non-smi fields). The emitted bytecode enters a new key
  (`not-found`, `index_[slot] = hap`, `index-spaces-left_--`) and
  rebuilds and restarts exactly as `find-body_`; on -2 it falls into the
  Toit loop, which is the method's failure block as before.

The candidate case writes three frame slots; the instruction never
writes the heap (the insertion is ordinary bytecode: INVOKE_AT_PUT,
STORE_FIELD_THIS). Compare is called once per candidate, as in format 1
and in Toit; a collection mutated by a `compare_` override is re-read on
the next probe (format 1's intrinsic re-reads it too).

## What the verifier and the proofs had to learn

All three are total spec functions of the frame and the heap; no new
stuck state is reachable from an accepted program (the soundness theorem
is unchanged, its proof extended). **No new trusted item**: TRUSTED.toml
has the same entries and counts (one justification's text names the new
opcode count) and the audit passes; the core uses only the existing heap
view accessors (`class_id`, `element`, `array_length`, `byte_at`, through
`locate`, `size_x`, `array_x`).

| | LOOP_REPEAT | LOOP_ARRAY | HASH_FIND |
|---|---|---|---|
| spec semantics (`spec.rs`, non-comment lines) | 17 (shared loop part included) | 15 | 95 |
| verifier rule (`verifier.rs` / `check.rs` executable, proven equal) | `loop_ok`, `loop_kinds`: 25 / 40, shared | +2 / +2 | `hf_ok`, `hf_kinds`: 22 / 40 |
| certificate inference (`infer.rs`, untrusted) | 20, shared | 0 | 10 |
| soundness (`sound_local_ops.rs`, `sound_hash.rs`) | `lemma_loop_taken`, `lemma_step_loop`: 135 lines, shared | (in the same lemma) | `sound_hash.rs`: 200 lines |
| spec crate Verus items | 892 -> 899 | -> 903 | -> 914 |
| core handler + refinement (`rloops.rs`, `rhash.rs`) | 231 lines, shared | (same file) | 425 lines |
| core crate Verus items | 837 -> 839 | -> 842 | -> 853 |
| checked loop (plain Rust, `machine.rs`, already trusted as a whole) | 25 | 30 | 90 |
| compiler (`byte_gen.cc`, `emitter.cc`) | 30, shared | +5 | 140 (the emitted find loop) |

Both word widths verify (`verified/check.sh`: spec 914, core 853 items,
0 errors, 64 and 32 bits). The verifier rules are small because the steps
are the existing rules composed: a loop step is POP + STORE_LOCAL of a
value + LOAD_LOCAL of the block + push of a value + a backward branch
whose target map is checked; HASH_FIND is three STORE_LOCALs of values,
two pushes and a forward branch with one pushed value. The proofs reuse
the generic local-step lemmas (`lemma_lgen`, `lemma_conf_move`) and, for
the key HASH_FIND pushes, `lemma_fast_at` (a value read by INVOKE_AT's
fast path is a heap value). The core's HASH_FIND loop is proven against
the recursive spec function with fuel (loop invariant: the remaining
probe equals the spec's), on 64 and 32 bits.

## Speed

Instructions inside the interpreters (callgrind `--toggle-collect` of
`Interpreter::run` resp. `toit_v2_run`, as DESIGN.md section 8; format 2
on the verified loop with TOIT_VERIFY=1), one VM build (this branch),
the format-2 programs compiled with the built-ins off (mask 0), each one
alone (1, 2, 4) and all (7). Ratio: to C++ format 1. `ir.sh`,
`ir/results.txt` (label `final`).

| workload | C++ f1 | f2, none | REPEAT | ARRAY_DO | HASH_FIND | all three | all / none |
|---|---:|---:|---:|---:|---:|---:|---:|
| richards | 1,023.6 M | 1,168.1 M (1.14) | 1,168.1 M | 1,168.1 M | 1,168.1 M | 1,168.1 M (1.14) | 0.0 % |
| deltablue | 650.2 M | 918.5 M (1.41) | 916.2 M | 829.2 M | 918.5 M | 826.9 M (1.27) | -10.0 % |
| pystone | 761.7 M | 900.0 M (1.18) | 874.4 M | 900.0 M | 900.0 M | 874.4 M (1.15) | -2.8 % |
| `repeat` 1 M iterations | 170.7 M | 248.0 M (1.45) | 154.0 M | 248.0 M | 248.0 M | 154.0 M (0.90) | -37.9 % |
| `List.do` 1 M elements | 226.5 M | 320.2 M (1.41) | 319.8 M | 197.2 M | 320.2 M | 196.9 M (0.87) | -38.5 % |
| map-int, 1 M lookups | 2,157.6 M | 2,285.8 M (1.06) | 2,191.7 M | 2,285.6 M | 2,060.9 M | 1,966.6 M (0.91) | -14.0 % |
| map-string, 200 k lookups | 629.7 M | 845.3 M (1.34) | 845.1 M | 820.3 M | 615.0 M | 589.9 M (0.94) | -30.2 % |
| map-set, 200 k inserts + 800 k updates | 2,502.2 M | 2,998.8 M (1.20) | 2,904.6 M | 2,954.8 M | 2,845.3 M | 2,707.0 M (1.08) | -9.7 % |

(The loop workloads are `t/loops.toit` of the fast-loop experiment plus
`list-do` and `map-set`; their `repeat` and `do` loops profit from the
loop steps too, which is why REPEAT also lowers map-int.)

Per built-in, against format 2 without it:

* LOOP_REPEAT: -38 % on a `repeat` loop (now 0.90 of C++; the unproven
  prototype that called the block itself reached 141 M), -2.8 % on
  pystone, -3 to -4 % on the map workloads; nothing elsewhere.
* LOOP_ARRAY: -38 % on `List.do` (0.87 of C++), -9.7 % on deltablue
  (1.41 -> 1.27 of C++: most of what is left of deltablue's gap besides
  the primitives), -3 % on map-string (`keys.do`).
* HASH_FIND: -27 % on string-keyed lookups (0.98 of C++ alone), -10 % on
  smi-keyed lookups, -5 % on inserts/updates. Smi keys gain less because
  their Toit probe was already cheap (`hash-code` and `==` are fast
  paths); what is left is `Map.[]`, `find_` and the compare block call,
  which format 1 makes too.

The whole differential suite (`run_suite.toit`, the 277 runnable tests,
bytecodes executed by the reference interpreter): format 2 without the
built-ins 373.2 M, with them 314.1 M (-15.8 %), format 1 306.8 M. The
excess of format 2 over format 1 goes from +21.6 % to +2.4 %.

Cost of having the built-ins in the run loop at all (same programs,
mask 0, against the VM of `sandbox-integration`, which measured 1,157.7 M /
913.3 M / 889.0 M): +0.9 % / +0.6 % / +1.2 % on richards / deltablue /
pystone, a register-allocation effect of the HASH_FIND arm (the two loop
steps cost nothing measurable: 1,157.7 M with them). Inlined, HASH_FIND's
handler cost +2.7 / +2.6 / +4.0 %; it is now out of line with the
registers by value (`rhash::op_hash_find_v`), which map lookups pay with a
call (+0.7 % on map-int).

Wall time (x86-64, 32 cores shared, load 17-22 during the runs: noisy;
`wall.sh 7`, minimum of 7 interleaved runs, `wall.txt`). Benchmarks: the
printed time per iteration. Workloads: the whole run minus the `empty`
workload's fastest run in the same format (4.4 ms; format 2 33.5 ms:
startup and the launch-time verification).

| ms | C++ f1 | f2, none | REPEAT | ARRAY_DO | HASH_FIND | all three |
|---|---:|---:|---:|---:|---:|---:|
| richards | 10.54 | 10.56 | 10.24 | 10.41 | | 10.19 |
| deltablue | 6.56 | 7.57 | 7.74 | 6.67 | | 6.66 |
| pystone | 7.44 | 6.87 | 6.68 | 6.72 | | 6.65 |
| `repeat` | 12.4 | 17.9 | 14.0 | 18.3 | 17.7 | 13.0 |
| `List.do` | 14.2 | 26.4 | 24.0 | 15.7 | 26.1 | 14.9 |
| map-int | 132.0 | 161.1 | 158.6 | 172.2 | 140.0 | 132.4 |
| map-string | 41.3 | 65.4 | 69.8 | 66.2 | 43.0 | 41.2 |
| map-set | 177.2 | 232.0 | 217.7 | 225.6 | 202.3 | 184.2 |

With all three, format 2 is within 5 % of C++'s wall time on every row
(deltablue 1.02, `repeat` 1.05, `List.do` 1.05, map-set 1.04), against
1.22-1.86 without them on the loop and map rows.


## Size

Device library (riscv32imac, the device configuration, opt 3, linked
with --gc-sections; `verified/vmverify/tests/device_size.sh`,
`devsize.sh`; base: `sandbox-integration` exported with git archive):

| component | base | proposal | |
|---|---:|---:|---:|
| core: verified loop and cold paths | 28,056 | 31,184 | +3,128 |
| of which `step::run_loop` | 19,964 | 20,954 | +990 |
| of which HASH_FIND out of line (`op_hash_find_v`, `find_x`, `probe_x`, `hf_at_x`) | 0 | 2,138 | +2,138 |
| verifier: checker | 17,674 | 18,830 | +1,156 |
| Rust library total (text + rodata, without libc) | 80,616 | 84,900 | +4,284 (+5.3 %) |

By built-in (the run loop and checker parts split by inspection, not by
separate builds): the two loop steps about 0.9 KB of run loop and 0.5 KB
of checker; HASH_FIND 2.1 KB out of line, 0.1 KB of run loop, 0.6 KB of
checker. The C++ VM and the C++ interpreter are unchanged (format 1 has
its intrinsics; the checked loop of the host build gets 3 more handlers).

Bytecode: the built-ins add 10 bytes to `SmallInteger_.repeat`, 10 to
`SmallArray_.do_` and 138 to `find-body_` (the find loop in bytecode
in front of the Toit fallback); richards' format-2 bytecodes 30,527 ->
30,685 bytes (+0.5 %), its snapshot with the shipped certificate +218
bytes (+0.2 %).

## Validation

All on this branch's head, artifacts `builtins/*.log`:

* `verified/check.sh --tests`: passed (Verus spec 914 / core 853 items,
  0 errors, 64 and 32 bits; audit; layout check; spec differential tests
  15/15; vmverify tests; sandbox ctests 121/121).
* Full ctest (build/host): 1194/1197, the three known environmental
  failures (version, reader, udp-reuse-port-test).
  The whole suite compiled in format 2 (`TOIT_BYTECODE_FORMAT=2 ctest`,
  trusted programs on the core's checked loop): 1193/1197, the three
  environmental failures and the known library race of
  services-network-test (PROGRESS.md; under load it failed 25 of 30 runs
  with the built-ins off and 22 of 30 with them on, `race.sh`).
* `verify_suite.toit`: 445 of 449 programs accepted, the 4 compile-error
  tests as before (the baseline's 439 plus 6 tests added since).
* `run_suite.toit --format both`: 274/277 runnable tests identical
  between the reference interpreter and the VM in each format, the three
  known failures of `suite-status.txt`.
* `untrusted_suite.toit`: 280/281 identical (format 1 trusted on C++
  against format 2 untrusted on the verified core); the one difference is
  the known `program-name-test` (PERMISSION_DENIED untrusted). The other
  known difference, `set-map-remove-first-test`, is identical now.
* `compare_trace.toit --format 2` (debug VM, the core's checked loop
  against the reference interpreter): the trace programs control 234,864,
  maps 213,197, numbers 24,333, sort 1,052,213 consecutive steps, and
  `t/trace_builtins.toit` (all three built-ins: large and small arrays,
  colliding keys, removals, a `compare_` override) 422,026, each up to the
  first environment-dependent primitive.
* Mutation campaign (`mutation_campaign.toit`, 12,000 mutants, seed 1,
  60 programs): 2,365 accepted, 0 stuck instructions. One finding, not
  in the built-ins: a mutant of `CowByteArray_`'s constructor (LOAD_LITERAL
  false at bci 1790 of byte-content-depth-test) makes a copy-on-write
  byte array mutable over a program-heap byte array, and the reference
  interpreter's model of `byte_array_replace` stops with ReadOnly
  (`interp/prims_impl.rs` `write_bytes`) instead of failing like the VM's
  verified Rust primitive (`blob_arg(.., MUTABLE)`). A fidelity gap of
  the reference interpreter's primitives, independent of this proposal
  (reproduce: `toit_spec_mutate --count 200 --seed 41 --max-steps 100000
  target/verify-suite/tests_byte-content-depth-test.dump`).
* `core_fuzz.toit`, ASan build, launch filter (the VM's own launch-time
  verifier), 20 minutes, seed 19, seeds map-test,
  set-map-middle-gap-test, rebuild-hash-index-test (maps of every size,
  removals, rebuilds, `repeat` and `do` loops): 95,357 mutants, 13,128
  accepted and run (11,710 exit 0, 1,065 exit 1, 323 exit 255, 1 exit
  95, 29 timeouts), 0 crashes, 0 stuck, 0 refusals. A second run, 10 minutes, seed 23, seeds
  `t/rep.toit`, `t/arr.toit`, `t/trace_builtins.toit`: 60,774 mutants,
  8,292 accepted and run, 0 crashes, 0 stuck, 0 refusals.
* 32-bit host (build/host32): sandbox ctests and layout check 122/122;
  the three built-in test programs untrusted, identical output.
* Shipped certificates: programs using all three built-ins verify with
  `TOIT_REQUIRE_CERTIFICATE=1` (the device path, `cert::verify_shipped`).
* Format 1 unchanged: 12 programs compile to identical program dumps
  with the reference compiler (`f1-identity.sh`).

## Risks

* Semantics are those of the Toit code in every case the fast path does
  not apply (the fall-through is the old code, and HASH_FIND's emitted
  loop is `find-body_` line by line). Where they could differ: a
  `compare_` override that mutates the collection during a lookup sees
  the next probe re-read the index and its size (Toit's loop keeps the
  old mask; format 1's intrinsic re-reads as here). Both are pathological
  and stay memory safe.
* HASH_FIND's emitted loop is hand-written bytecode in the compiler
  (~150 lines of `byte_gen.cc`) that must track `find-body_`; a change of
  the Toit method or of `HashedInsertionOrderedCollection_`'s field
  layout must change it too (format 1's C++ intrinsic has the same
  coupling, `Instance::MAP_*_INDEX`). The verifier checks it like any
  code, so a mismatch is a functional bug, not a safety one.
* The run loop's register allocation: the HASH_FIND arm costs about 1 %
  on programs without maps (above). Further opcodes in the loop may move
  this either way; tail-call dispatch (not available on stable Rust)
  would remove the effect.
* The built-ins reuse opcode numbers 101..103 of the format-1 intrinsics
  (the C++ `Opcode` enum); a later format-2 opcode must take 104.
* Proof maintenance: the HASH_FIND core loop is the first loop over the
  heap in a register handler; its invariant ties it to a recursive spec
  function with fuel, so changes to `fast_at` or `fast_size` ripple into
  it (as into INVOKE_AT).

## HASH_DO

Not done: it is not a small variation of the others. `Map.do`/`Set.do`
iterate a `List` backing (fast_at's list path, not a plain array) with a
stride of 2 for maps, push two values, and skip tombstones with skip
counts that the format-1 intrinsic compacts (a heap write); a write-free
step would fall through at every tombstone. It would be a fourth step
shape with its own rule and proof, for about 1.7 % of the suite's
format-2 instructions (note 16) and nothing on the three benchmarks.

## Recommendation

Adopt the two loop steps first, as one decision: they share the verifier
rule (`loop_ok`/`loop_kinds`, one branch target, existing kinds only),
the soundness lemma and the core helpers; together +11 spec and +5 core
proof items, no trusted item, about 1.4 KB on the device, no measurable
cost on code that does not use them. They remove the largest part of
deltablue's remaining gap (1.41 -> 1.27 of C++), make `repeat` and
`List.do` faster than format 1 (0.90 / 0.87), and help pystone (-2.8 %).
If only one: LOOP_ARRAY (bigger benchmark effect).

Then HASH_FIND: the biggest win on map-heavy code (string keys -27 %,
smi keys -10 %, inserts -5 %; with the loops, lookups at 0.91-0.94 of C++,
inserts at 1.08), proven with no trusted item, but the larger cost: +11 spec and
+11 core items including the first heap-walking loop in a register
handler, 2.8 KB on the device, 138 bytes of compiler-emitted bytecode
that must track `find-body_`, and about 1 % on code without maps from the
run loop's register allocation. Worth it for workloads with maps (the
system services, JSON, RPC); if devices are tight on flash, it is the one
to leave out.

What remains open on this branch: wall-clock times on an idle machine
(above, measured under load), the instruction totals of the whole
untrusted suite under callgrind (`suite-ir.sh`, written, not run; the
step totals above stand in for them), a device measurement of the speed effect,
HASH_DO (above), and moving the emitted find loop next to `find-body_`
(e.g. a format-2-only Toit body) if the owner prefers Toit to bytecode
for it.
