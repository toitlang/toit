# Experiment: trusted containers on the core

Branch `experiment/trusted-on-core` (`proposal/builtins` + `sandbox-integration`).
Not to be merged without the owner's decision. Question: can the verified
core run trusted code (the system process, first-party programs) as fast
as the C++ interpreter, so that it can replace `src/interpreter_run.cc` and
format 1? Scripts and raw numbers: /home/flo/work/opentoit-sandbox-artifacts/
trusted-on-core (`ir.sh`, `cli-ir.sh`, `wall.sh`, `calls.sh`, `prof.sh`,
`f2-suite.sh`, `ir/results.txt`, `suite/`, `devsize/`).

## What was built

- **Format 2 everywhere.** The CMake option `TOIT_SYSTEM_FORMAT2` compiles
  the toit CLI, the boot snapshot of toit.run (the system process) and the
  run image in format 2 (`build/host-f2`). `-O2` still compiles a first
  pass in format 1 for the type propagator.
- **Trusted token.** `Interpreter::run_v2` sends trusted processes whose
  program was not verified to the verified loop (`TOIT_V2_TRUSTED`,
  `ffi::Accepted::trusted_program`). Debug builds verify trusted format-2
  programs at launch, as a check on the compiler.
  `TOIT_TRUSTED_CHECKED_LOOP=1` restores the checked loop for comparisons.
- **Cheap C++ calls (epoch).** `toit_v2_primitive` replaces the lookup and
  call wrappers. It is one FFI hop, the primitive is called as the C++
  interpreter calls it, and the GC-and-retry path runs out of line.
  `ObjectHeap::v2_epoch_` changes at every GC and every task switch. When
  the epoch is unchanged, the core completes PRIMITIVE, ALLOCATE and
  double boxing on the registers, with no reload and no room rescan.
- **Unchecked mode.** Trusted programs run with `Program2::unchecked`.
  Field accesses on receivers other than `this`, stores into the program
  heap and the accessor fast paths are not checked; in the spec a failed
  access is stuck (`spec::unchecked_fail`). The verifier accepts the mode
  only if `trusted`. The soundness theorems are stated for programs
  without the mode, which covers every untrusted program; for that case
  the statement is unchanged and has 0 admits.
  `TOIT_V2_CHECKED_FIELDS=1` turns the mode off. I chose a mode flag over
  twin opcodes because twins need new opcodes across the spec, the
  verifier, the inference, the reference interpreter, the compiler and
  the tools. The cost of the flag is below.
- **Not done:** unchecked lambda/initializer tail calls (rare opcodes,
  machine paths), HASH_DO and the re-entrant intrinsics, and a separate
  measurement of the epoch on its own (the old call path is gone; "before"
  below is the same build before the change).

## What runs

The whole host suite with everything in format 2 on the verified loop
(system process, CLI and tests): **1192/1197**. ctest counted 1191; the
1192nd is verified_core_verify, which passed when rerun alone (row "Not a
real failure"). The format-1 baseline is 1194/1197. Failures:

| Class | Tests |
|---|---|
| Environmental, also in format 1 | version and reader (not built), udp-reuse-port-test (no multicast) |
| Known library race, also in format 1 under load | services-network-test |
| Format-2 accounting difference (same on the checked loop) | bytes-allocated-test: an external byte array counts 1,576 bytes more, after the 2 GCs it causes; cause not identified |
| Not a real failure | verified_core_verify: proof instability after the merge (fixed in 67d7003e); the second run overlapped a measurement edit and passed when rerun |

## Speed

Callgrind Ir inside `Interpreter::run` (all processes, primitives and GC
included), in millions. The ratio to C++ is in parentheses.

- "before": the trusted token only.
- "checked": the final build with `TOIT_V2_CHECKED_FIELDS=1`, the code
  shape untrusted programs run.
- "trusted": the final build, unchecked mode.

The built-ins of note 19 are on in every format-2 column.

| Workload | C++ f1 | core before | core checked | core trusted |
|---|---:|---:|---:|---:|
| richards | 1,023.6 | 1,168.3 (1.14) | 1,193.9 (1.17) | 1,131.8 (1.11) |
| deltablue | 650.2 | 828.8 (1.27) | 828.2 (1.27) | 785.6 (1.21) |
| pystone | 761.7 | 876.3 (1.15) | 877.9 (1.15) | 839.3 (1.10) |
| `repeat` | 170.7 | 156.1 (0.91) | 158.0 (0.93) | 158.0 (0.93) |
| `List.do` | 226.5 | 199.0 (0.88) | 200.9 (0.89) | 200.9 (0.89) |
| map-int | 2,157.6 | 1,961.7 (0.91) | 1,979.9 (0.92) | 1,979.8 (0.92) |
| map-string | 629.7 | 591.4 (0.94) | 593.5 (0.94) | 593.3 (0.94) |
| map-set | 2,502.2 | 2,703.4 (1.08) | 2,579.6 (1.03) | 2,562.1 (1.02) |
| json encode+decode | 1,112.0 | 1,541.6 (1.39) | 1,508.5 (1.36) | 1,490.1 (1.34) |
| yaml encode+decode | 3,477.1 | 5,261.9 (1.51) | 5,218.1 (1.50) | 5,209.3 (1.50) |
| tison | 144.9 | 186.0 (1.28) | 181.5 (1.25) | 180.2 (1.24) |
| strings/format | 3,010.9 | 3,801.0 (1.26) | 3,750.8 (1.25) | 3,750.8 (1.25) |
| RPC ping-pong | 342.7 | 667.4 (1.95) | 629.7 (1.84) | 619.6 (1.81) |
| CLI: container install | 33.1 | | 31.6 (0.95) | 31.5 (0.95) |
| CLI: envelope show | 129.8 | | 142.0 (1.09) | 141.4 (1.09) |

Wall time is secondary (minimum of 5 runs, machine load 21-30). For the
benchmarks it is the printed time per iteration; for the rest it is the
whole run minus the empty program.

| | richards | deltablue | pystone | json | yaml | strings | RPC | map-set |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| C++ f1, ms | 10.08 | 6.58 | 7.27 | 131.3 | 636.3 | 286.8 | 69.1 | 167.6 |
| core trusted / C++ | 0.97 | 0.97 | 0.93 | 1.28 | 1.16 | 1.15 | 1.42 | 1.05 |

Instructions per operation (loop of 1,000,000 iterations minus the empty
loop; each iteration includes a Toit call and a field read):

| | C++ f1 | core before | core after |
|---|---:|---:|---:|
| C++ primitive call | 68 | 676 | 293 |
| allocation (instance) | 143 | 336 | 258 |
| double boxing | 55 | 273 | 215 |

These costs are now a small part of trusted workloads (call counts from
`calls.sh` times the excess over C++):

- C++ primitives: 1.6-1.8% of strings and json, 6.9% of RPC.
- Allocation: 2.2% of yaml and deltablue.

The large remaining item is the machine's slow paths. NON_LOCAL_RETURN,
NON_LOCAL_BRANCH, TRY and THROW always leave the register loop, and every
return from the machine rescans the room of all frames
(`room::ensure_room_all`). That costs 13-22% of yaml and RPC and 7% of
json. A measurement-only prototype that skipped the rescan (unsound, not
committed) reached:

- json 1.24, yaml 1.27, RPC 1.43, strings 1.17 times C++;
- richards 1,123 M.

The flag of the unchecked mode costs code that keeps the checks: richards
1,168 → 1,194 M (+2.2%), deltablue +0%, pystone +0.2%. Twin opcodes would
remove that cost.

## Size

Device library: riscv32imac, opt 3, `device_size.sh`, Rust without libc.

| | bytes |
|---|---:|
| base (this branch's merge, untrusted-only core) | 80,746 |
| trusted-capable core (this branch) | 81,230 (+484) |

On the C++ side, removing the interpreter and format 1 would delete:

- ESP32-C6: 26.1-27.5 KB of flash, of which about 21.7 KB is IRAM. Almost
  all of it is `Interpreter::run` (19.1 KB), plus hash_find/hash_do, the
  dispatch tables, the format-1 helpers of interpreter.cc and
  MethodEntryTable.
- ESP32 (from objects): 20.8-22.3 KB.
- The C++ format-1 verifier: nothing, because devices do not link it.

Format-2 snapshots are 4% smaller (the host boot snapshot is 185.8 KB
against 188.8 KB). Compared with today's firmware, which carries both
interpreters, replacing saves about 27-30 KB of flash and 21.7 KB of IRAM.
Compared with upstream firmware without the sandbox, the core costs about
+55-62 KB.

## What remains for format 2 only (step 3)

The total is 35-55 engineer-days, or 50-75 if the propagator is ported.
Xtensa is not included.

| Item | Work | Effort |
|---|---|---|
| Type propagator / `-O2` | The propagator interprets format 1. The proper fix is to port it to format 2 (frames, finally records, block refs, built-ins) and regenerate the gold files. The interim fix keeps format 1 as a compiler-internal IR that is never shipped. | 12-20 d (interim 0.5 d) |
| Machine slow paths | Register fast paths for NON_LOCAL_RETURN/BRANCH, TRY and THROW without finally records, and room facts for the paths that only pop frames (removes the rescan) | 3-5 d, proofs |
| Allocation | Bump allocation in the core (a new trusted heap accessor) instead of the C++ call chain | 2-3 d |
| Unchecked twins | Twin opcodes instead of the mode flag (removes the 0-2% cost for untrusted code) | 3-4 d |
| Stack traces, profiler, trace | They exist for format 2; delete the format-1 walks and printing.cc | 2-4 d |
| Tools, snapshot/image | snapshot.toit already decodes format 2. Drop the format-1 tables and bump the envelope version. | 1.5-2 d |
| Tests | tests/toitp, tests/optimizations, bytecode-test.cc, the type-propagation golds, the format-1 CLI tests | 3-5 d |
| C++ verifier, format-1 hardening, MethodEntryTable, `Interpreter::run` | Delete them; replace `Method` handles by method indices | 5-8 d |
| Hosts and devices | Cargo targets for the cross hosts. C6/H2 bring-up. C3 (no atomics). EC618 (thumbv7m). | 13-25 d |
| **Blocker: Xtensa** (ESP32, S2, S3) | Upstream Rust has no Xtensa target, and the esp-rs fork has open wrong-code bugs | cannot be estimated |

## New trusted items

TRUSTED.md section 9 and TRUSTED.toml:

- `ffi::Accepted::trusted_program`: the trusted token.
- `step::trusted_field_accesses`: the unchecked-mode assumption.
- The epoch contract inside `primitive::gc_call_primitive`,
  `alloc::gc_allocate_instance` and `alloc::gc_allocate_double`.
- `toit_v2_primitive`: the extern declaration.

The old wrappers `lookup_primitive` and `PrimitiveRef` are gone.

**Gate:** `verified/check.sh --tests` passed (spec 917 and core 850 items
at both widths, the audit, the no-panic check, 121/121 sandbox ctests).

## Verdict

**Not yet for all first-party code.**

- **Compute-bound code:** fast enough. The core runs at 1.10-1.21x the
  C++ instructions, and its wall time is equal or better (0.93-0.97).
- **Loops and maps:** faster than C++.
- **System-style code:** not yet (json, yaml, string formatting, RPC):
  1.25-1.81x in instructions and 1.15-1.42x in wall time.

The cause is no longer the C++ calls. It is the out-of-line machine paths
for non-local control flow and exceptions, and the room rescan after
them. A sound version of the rescan fix brings these workloads to
1.17-1.43x. Register fast paths for NON_LOCAL_RETURN/BRANCH and TRY, plus
inline allocation, should close most of the rest; that is about one to
two weeks with proofs. Then the remaining blockers are the propagator
decision and Xtensa.

# Follow-up: branch experiment/trusted-fast (2026-11-11)

Branch `experiment/trusted-fast` (`experiment/trusted-on-core` +
`sandbox-integration`). Scripts and raw numbers:
/home/flo/work/opentoit-sandbox-artifacts/trusted-fast (`all.sh` runs
every workload in the three configurations, `ir/results.txt`,
`callers.sh`/`sites.sh` for the slow-path call sites, `wall.sh`,
`heavy.sh` for the gates, `devsize/`). The configurations:

- **C++ f1**: build/host, format 1 on the C++ interpreter.
- **core checked**: build/host-f2, the snapshot compiled without the
  unchecked twins: exactly the code untrusted programs run.
- **core trusted**: build/host-f2, the snapshot with the twins
  (`TOIT_V2_UNCHECKED=1`); the embedded CLI is compiled that way.

The `tison` workload of the predecessor ran out of memory in every
configuration (`tison.decode` of the 400-entry document); it now encodes
and decodes 40 entries 100 times. Its old numbers are not comparable.

## What was built

1. **Register fast paths for non-local control flow** (rnonlocal.rs,
   out of line: inlined, they changed the run loop's register allocation,
   +6% on richards). NON_LOCAL_RETURN and NON_LOCAL_BRANCH pop frames on a
   copy of the registers (`pop_to`) while no frame on the way has a
   handler, then complete in the target frame (`rarrays::ret_r` for the
   return); TRY under a call's fast-path check; UNWIND after a normal
   completion; the return of a try block into its finally code
   (`ret_try_r`); UNWIND with a token that resumes a non-local return or
   branch (the only finally record, `unwind_resume_v`). INVOKE_BLOCK and
   the static/initializer tail calls already had fast paths.
2. **Room facts instead of rescans.** `room_ok` now asks room for every
   frame without the finally records plus the top frame with them, so the
   records coming and going need no rescan. After a slow path that kept
   the frames below the top and the stack length (a call, a return, an
   unwinding: `room::top_kept`, proven from the machine paths'
   postconditions and `unwind::lemma_unwind_prefix`) `step::resume_kept`
   checks the top frame only. `ensure_room_all` (a scan of every frame)
   remains after a GC that shrank the stack, a task switch, raises and the
   rare machine paths: in RPC 30,000 scans instead of 495,000.
3. **Calls into C++ and allocation.** Inline bump allocation of
   instances and doubles (`alloc::bump_instance`, `bump_double`: the
   new-space fast path of `SemiSpace::try_allocate` and the initialization
   of `ObjectHeap::allocate_instance`/`allocate_double`, a new trusted
   item); the C++ path with its GC only when new space is full. Core
   primitives without a Rust port are masked out of the policies' core
   arities (`toit_v2_core_ported`), so their PRIMITIVE skips the Rust
   dispatch (32 instructions of argument copying per call).
4. **Unchecked twins instead of the mode flag** (format note 20, opcodes
   104..113): trusted-only twins of the field accesses, emitted by the
   compiler with `-Xv2_unchecked` / `TOIT_V2_UNCHECKED=1`, typed as their
   base by the verifier and accepted only in the unchecked mode (trusted
   rules); spec, verifier, executable checker, inference, reference
   interpreter, core, checked loop, compiler, disassembler. The checked
   handlers no longer test a flag. `TOIT_V2_CHECKED_FIELDS` is gone.

Not done: register paths for an unwinding that enters finally code and for
calls and returns while finally records exist (they run on the machine,
now without rescans); a leaner C++ primitive call (below); unchecked
lambda/initializer tail calls, HASH_DO; the bytes-allocated difference.

## Progression (core trusted; Ir in millions, ratio to C++ f1)

| Step | richards | deltablue | pystone | json | yaml | strings | RPC |
|---|---:|---:|---:|---:|---:|---:|---:|
| C++ f1 | 1,023.6 | 650.3 | 761.8 | 1,111.9 | 3,475.7 | 3,010.9 | 342.6 |
| start (merge) | 1,131.9 (1.106) | 785.6 (1.208) | 839.3 (1.102) | 1,490.0 (1.340) | 5,207.5 (1.498) | 3,750.8 (1.246) | 619.5 (1.808) |
| 1. fast paths | 1,131.4 | | | 1,386.9 (1.247) | 4,374.9 (1.259) | | 482.2 (1.408) |
| 3. mask + bump | 1,127.5 | 770.4 | 828.2 | 1,375.5 | 4,280.7 | 3,332.3 (1.107) | 478.3 |
| 4. twins | 1,078.0 (1.053) | 760.9 (1.170) | 810.3 (1.064) | 1,368.7 | 4,263.1 | 3,333.1 | 469.4 |
| 2. room facts | | | | 1,345.2 | 4,197.0 | | 454.1 |
| 1. UNWIND resume | 1,077.9 (1.053) | 760.8 (1.170) | 810.2 (1.064) | 1,331.6 (1.198) | 4,181.2 (1.203) | 3,333.1 (1.107) | 443.6 (1.295) |

Core checked (untrusted code): richards / deltablue / pystone 1,193.9 /
828.2 / 877.9 at the start (with the mode flag; 1,168.3 / 828.8 / 876.3
before the flag existed), 1,165.8 / 807.6 / 862.3 now: **1.139 / 1.242 /
1.132** of C++ (target 1.14 / 1.27 / 1.15).

## Final ratios (Ir)

| Workload | C++ f1 | core checked | core trusted |
|---|---:|---:|---:|
| richards | 1,023.6 | 1,165.8 (1.139) | 1,077.9 (1.053) |
| deltablue | 650.3 | 807.6 (1.242) | 760.8 (1.170) |
| pystone | 761.8 | 862.3 (1.132) | 810.2 (1.064) |
| `repeat` | 170.7 | 155.6 (0.912) | 155.6 (0.912) |
| `List.do` | 226.5 | 198.5 (0.877) | 198.5 (0.876) |
| map-int | 2,154.6 | 1,961.5 (0.910) | 1,961.4 (0.910) |
| map-string | 629.6 | 589.3 (0.936) | 589.2 (0.936) |
| map-set | 2,499.2 | 2,553.0 (1.022) | 2,534.3 (1.014) |
| json | 1,111.9 | 1,353.7 (1.217) | 1,331.6 (1.198) |
| yaml | 3,475.7 | 4,203.3 (1.209) | 4,181.2 (1.203) |
| tison (new size) | 96.8 | 101.5 (1.048) | 101.1 (1.044) |
| strings/format | 3,010.9 | 3,333.7 (1.107) | 3,333.1 (1.107) |
| RPC ping-pong | 342.6 | 456.3 (1.332) | 443.6 (1.295) |
| CLI: container install | 33.1 | | 29.4 (0.888) |
| CLI: envelope show | 129.8 | | 134.2 (1.034) |

## Per operation (instructions, each with a Toit call; minus the empty loop)

| | C++ f1 | core before | core now |
|---|---:|---:|---:|
| C++ primitive call | 68 | 293 | 242 |
| allocation (instance) | 143 | 258 | 164 (trusted), 186 (checked) |
| double boxing | 55 | 215 | 100 |

The primitive call: the Rust side (`rarrays::cxx_primitive_v`: writing
the registers back, saving the header, the epoch compare, the return fast
path) is 110 instructions with spills (the function keeps the registers
live for its slow paths), `toit_v2_primitive` 47 plus 5 for an
out-of-line `leave_primitive`. A lean fast path (only the stack top and
record top stored, the registers not written back into the machine, a
separate cold completion) should reach about 150.

## Where the rest goes

RPC: the remaining slow paths are the unwindings that enter finally code
(a non-local return out of a `try`/`finally`: about 47,000 in the
workload) and the calls and returns inside that finally code (the records
move): 62 M of 444 M. Register versions of these two would bring RPC to
about 1.2. json and yaml: the run loop itself (dispatch, calls and
returns), not slow paths; 2-3% each are unwindings as above.

<!-- WALL, SIZE, GATES -->

