# Format 2 as the default (migration step 3)

Branch `plan/format2-default` (from `sandbox-integration`). The plan agreed
with the project owner: one interpreter (the Rust core, verified/core) and
one bytecode format (format 2). This step makes format 2 the default for
every program on host builds; the next step deletes the C++ interpreter and
format 1. Artifacts and scripts:
/home/flo/work/opentoit-sandbox-artifacts/format2-default.

## The default and how to switch back

| What | Default now | Format 1 |
|---|---|---|
| Compiler (toit.compile, toit.run, `toit compile/run`) | format 2 when the build has the verified core | `-Xbytecode_format=1`, or `TOIT_BYTECODE_FORMAT=1` in the environment |
| Embedded programs (toit CLI, toit.run boot snapshot with the system process, run image) | the build's format | CMake `-DTOIT_BYTECODE_FORMAT=1` |
| The whole build (compiler default and embedded programs) | `TOIT_BYTECODE_FORMAT=2` if `TOIT_VERIFIED_CORE` is on, else 1 | `cmake -DTOIT_BYTECODE_FORMAT=1` |

Precedence in the compiler (src/compiler/program_builder.cc,
`requested_bytecode_format`): an explicit `-Xbytecode_format=N`, then
`TOIT_BYTECODE_FORMAT` from the environment, then the build's default
(`TOIT_DEFAULT_BYTECODE_FORMAT`, from the CMake cache variable
`TOIT_BYTECODE_FORMAT`). The old CMake option `TOIT_SYSTEM_FORMAT2` is gone:
a build configured with `-DTOIT_BYTECODE_FORMAT=1` is the old default
build, one with `-DTOIT_BYTECODE_FORMAT=2` is the old `build/host-f2`.
Running the suite "everything in format 1" is a build with
`-DTOIT_BYTECODE_FORMAT=1` (no environment needed); for one program,
`-Xbytecode_format=1` or `TOIT_BYTECODE_FORMAT=1`.

The VM runs both formats as before: format 1 on the C++ interpreter,
format 2 on the core (`Program::is_format2`, the `TBC2` tag), so programs
of both formats can be compared on one VM.

## Trusted and untrusted compilation

There are two kinds of format-2 code:

- **Trusted (first-party), the default.** The compiler emits the
  trusted-only unchecked twins of the field accesses (format note 20) and
  the built-ins of note 19. No certificate. The program runs on the
  verified loop without verification (the trusted token). It cannot run as
  an untrusted container: the launch and install verifier reject the twins
  ("unchecked opcode ... in a program not in the unchecked mode").
- **Untrusted.** Only checked opcodes (the built-ins are verified and
  stay), and `toit.compile -w` ships the certificate
  (verified/spec/format/18-shipped-certificate.md) that the device checks
  at install.

The user-facing switch is `--untrusted`:

    toit compile --untrusted --snapshot -o prog.snapshot prog.toit   # toit.compile --untrusted -w ...
    toit run --untrusted prog.toit                                    # compiles untrusted, runs sandboxed
    toit.run --untrusted -w prog.snapshot prog.toit                   # writes the snapshot (no certificate)

`--untrusted` implies format 2 (`toit.compile --untrusted
-Xbytecode_format=1` is an error). `-Xuntrusted` is the same flag.
Low-level overrides: `-Xv2_unchecked=false` or `TOIT_V2_UNCHECKED=0`
compile checked code without making the program untrusted; the sandbox
tests use this for their trusted drivers, which start their own image as
an untrusted container.

## -O2 and the type propagator

Decision: **format 1 stays a compiler-internal intermediate**; the
propagator is not ported. `-O2` compiles a first pass in format 1 in
memory, the propagator interprets it (src/compiler/propagation/), the type
oracle maps the results back to IR nodes, and the second pass emits the
requested format. Only the second pass is written. `--propagate` (the
type-propagation tests) compiles in format 1 throughout, since its output
names format-1 bcis.

Cost comparison: type_propagator.cc is a second interpreter over the
format-1 instruction set (1,982 lines plus type_scope/type_stack, 5,651
lines in propagation/ with the primitive tables). Porting it means new
frame, block-reference, finally-record and built-in handling and new gold
files for 52 tests: 12-20 days (EXPERIMENT-trusted.md). The intermediate
was already in place (compiler.cc) and needs no work; it costs one extra
code generation at `-O2` only, and keeps about 200 lines of format-1
emission (emitter.cc, byte_gen.cc, program_builder.cc) plus
`src/bytecodes.h` and the `Method` class alive in the compiler.

Effect (o2.sh, compiler of build/host; bytecode bytes / methods / virtual
calls / static calls):

| Program | f1 -O1 | f1 -O2 | f2 -O1 | f2 -O2 |
|---|---|---|---|---|
| richards | 28,745 / 905 / 398 / 891 | 19,864 / 657 / 276 / 641 | 26,231 / 905 / 398 / 891 | 18,104 / 657 / 276 / 641 |
| deltablue | 30,266 / 948 / 446 / 961 | 20,962 / 682 / 312 / 711 | 27,667 / 948 / 446 / 961 | 19,149 / 682 / 312 / 711 |
| pystone | 28,568 / 902 / 398 / 881 | 19,592 / 637 / 273 / 621 | 26,078 / 902 / 398 / 881 | 17,891 / 637 / 273 / 621 |
| toit CLI | 308,109 / 7,184 | 289,148 / 6,800 / 4,076 / 13,552 | 287,212 / 7,184 | 269,075 / 6,800 / 4,076 / 13,552 |
| system (toit.run) | 61,894 / 1,785 | 54,667 / 1,633 / 794 / 2,084 | 56,515 / 1,785 | 49,766 / 1,633 / 794 / 2,084 |

The `-O2` programs have the same methods and the same virtual and static
calls in both formats; the bytecodes shrink by the same fraction (richards
0.691 in format 1, 0.690 in format 2). Instructions (callgrind in
`Interpreter::run`, millions, bench.sh with `OPT=-O2`; `trs` is format 2
trusted, the default):

| | cxx -O1 | cxx -O2 | trs -O1 | trs -O2 | trs/cxx at -O2 |
|---|---:|---:|---:|---:|---:|
| richards | 1,024.3 | 981.0 | 1,075.3 | 1,031.4 | 1.051 |
| deltablue | 652.5 | 621.1 | 758.8 | 735.4 | 1.184 |
| pystone | 767.4 | 755.1 | 811.9 | 799.9 | 1.059 |
| json | 1,117.1 | 1,042.9 | 1,314.5 | 1,244.5 | 1.193 |
| RPC | 343.9 | 329.5 | 412.7 | 401.5 | 1.218 |

`-O2` saves 1.5-6.6% in both formats; the saving is up to 1.7 points
smaller on the core for deltablue and RPC (the same program, executed by a
different interpreter).

## Devices

ESP32 targets keep format 1: the IDF component compiles the system
snapshot and the entry program with `TOIT_BYTECODE_FORMAT=1`
(toolchains/idf/components/toit/CMakeLists.txt), and the EC618 rule in the
Makefile does the same. Cross builds (Raspberry Pi, Windows, ...) have no
verified core, so their `TOIT_BYTECODE_FORMAT` defaults to 1, and their
embedded programs, compiled by the host compiler, get
`TOIT_BYTECODE_FORMAT=${TOIT_BYTECODE_FORMAT}` (src/CMakeLists.txt).
`toit compile --os/--arch` (executables for another target, from the
cross builds' vessels) defaults to format 1 too.

A user's `toit compile --snapshot` is format 2 now; an ESP32 runs only
format 1. `toit tool firmware container install` warns when a format-2
snapshot goes into an envelope whose system snapshot is format 1; compile
device containers with `-Xbytecode_format=1` (or `TOIT_BYTECODE_FORMAT=1`)
until the device has the core.

Switching a device to format 2 needs:

- the verified core in its firmware (Kconfig `TOIT_VERIFIED_CORE`): today
  ESP32-C6 and H2 link it (PROGRESS.md "Device builds"); the classic ESP32,
  S2 and S3 are Xtensa, for which upstream Rust has no target and the
  esp-rs fork has open wrong-code bugs (the blocker); the C3 lacks atomics;
  the EC618 needs a thumbv7m bring-up; the cross hosts need cargo targets;
- dropping `TOIT_BYTECODE_FORMAT=1` from the IDF component for those
  targets, and an envelope property saying which formats the firmware runs
  (instead of the warning's guess from the system snapshot);
- measurements on hardware: the core's speed from flash, the IRAM budget
  (the trusted loop is not in IRAM), install time of untrusted containers
  (PROGRESS.md: 1.3-13 s estimated).

## Converted tools and tests

Every tool that reads bytecodes already decoded format 2 (tools/snapshot.toit
since phase 2); the default flip exposed the places that assumed format-1
method ids or header sizes:

| Item | Change |
|---|---|
| tools/snapshot.toit | `method-from-absolute-bci` finds a method by its id (format-2 headers have no fixed size); `dispatch-table-method-ids` maps format-2 dispatch entries (method indices) to method ids |
| tools/toitp.toit (`toit tool toitp`) | the dispatch table printed with method ids |
| tests/toitp (dispatch-snap, method-snap, bytecodes-snap, bytecodes-toitp) | method ids instead of `MethodInfo.absolute-entry-bci`; the wide non-local return is format 1 only |
| tests/optimizations/utils.toit | static call targets through `method-id-for-target` |
| tools/toit.toit | `toit compile --untrusted` |
| tools/firmware.toit | the format warning above |
| tests/sandbox (CMake, run-untrusted.cmake, sandbox-util, install-verdict) | images without twins; untrusted snapshots with `--untrusted` |
| verified/tools/untrusted_suite.toit | the reference side is `-Xbytecode_format=1` explicitly |
| lib/system/services.toit | the uninstall bug below |

Checked and unchanged (pass in format 2): stack traces and their
decoding in the system process, the profiler tests (the `repeat` built-in
keeps `repeat` out of profiles, as format 1's intrinsic did), the LSP
tests (bci to source), the envelope and firmware tests, snapshot-to-image
and the image tests, the vessels, the negative tests, the type-propagation
tests. tools/stacktrace.toit decodes native ESP-IDF backtraces, not
bytecodes. The intrinsics named in lib/core (`#primitive.intrinsics.*`:
smi-repeat, array-do, hash-find, hash-do) stay: in format 2 the compiler
lowers them to the built-ins of note 19 or to their Toit fallback.

## Format-1-only leftovers (to delete in the next step)

Marked `FORMAT-1-ONLY` in the source:

- tests/sandbox/field-access-test.toit, runtime-hardening-test.toit
  (C++ interpreter hardening), verify-reject-test.toit (C++ verifier);
- the format-1 half of tests/sandbox/invalid-utf-8-literal-test.toit;
- tests/sandbox/cli/format1-{refused,allowed}-snapshot
  (tests/sandbox/CMakeLists.txt);
- tests-toitp-bytecode-match-test (tests/toitp/bytecode_lister.cc against
  the `BYTE-CODES` table of tools/snapshot.toit).

Kept on purpose (compiler-internal format 1, as long as the propagator
interprets it): tests/type_propagation (52 golds, `-Xpropagate`),
tools/dump_types.toit, `BYTE-CODES` in tools/snapshot.toit,
tests/ctest/bytecode-test.cc (src/bytecodes.h ordering). Lost with the
C++ interpreter unless reimplemented on the core: the
`TOIT_CHECK_PROPAGATED_TYPES` CI job (.github/workflows/ci-host-build.yml).

## What still depends on format 1

From an inventory of the tree (line counts from `wc -l`, "est" where
format-1 code is mixed with shared code):

| Area | Files | Lines | Effort |
|---|---|---|---|
| C++ interpreter | src/interpreter_run.cc (all but `run_v2` hand-off, 2,329), interpreter_core.cc (`hash_do`, `fast_size`: ~145 of 439; `fast_at`, `compare_numbers` stay for primitives), interpreter.cc (~250 of 328), interpreter.h (~150; FRAME_SIZE, LINK_*_SLOT, UNWIND_REASON move to the compiler), method_entries.cc/.h (313, users process_group.cc, primitive_core.cc), objects.cc/objects_runtime.cc/objects.h Stack helpers (~115 est), primitive_core.cc spawn/task branches (~32), printing.cc (~215, only for `Interpreter::trace`) | ~3,560 | 3-4 d (replace `Method` handles by method indices in Process/Program/scheduler) |
| C++ verifier and hardening | src/verifier.cc (~2,100 of 2,234), verifier.h (~60), toit_run.cc `--verify` format-1 paths, `--fuzz`, `--dump` (~150), `FORMAT_2_REQUIRED`/`untrusted_format1` gating (~45 in primitive_programs_registry.cc, primitive_snapshot.cc, verifier_v2.cc, interpreter_v2.cc/.h), `TOIT_CHECKED_FIELD_ACCESS` | ~2,360 | 1-2 d |
| Snapshot and program | program.h `frame_marker`, entry `Method` accessors (~25); snapshot/image code is format-neutral; bump the envelope version | ~25 | 0.5 d |
| Compiler | emitter.cc (15 format checks), program_builder.cc (8), byte_gen.cc (6), compiler.cc, toitc.cc: ~200 lines of format-1 emission kept as the propagator's IR; only the user-facing selection goes (`-Xbytecode_format=1`, `TOIT_BYTECODE_FORMAT=1`, the CMake variable: ~35) | keep ~200 | 0.5 d |
| Tools | tools/snapshot.toit format-1 header and `BYTE-CODES` (~140), needed by dump_types and the propagation tests while `--propagate` writes format 1 | keep | 0 |
| Tests | the FORMAT-1-ONLY list above (~560 lines) | ~560 | 0.5 d |
| Flags | `untrusted_format1`/`TOIT_UNTRUSTED_FORMAT1`, `TOIT_VERIFY_VERBOSE`; `bytecode_format` becomes internal | | with the above |
| Devices | toit_vm links interpreter_run.cc, method_entries.cc, printing.cc into every firmware; `Interpreter::run` is IRAM_ATTR | | blocked by Xtensa (see Devices) |

The VM side is about 5,950 lines. Deleting them on hosts is 6-8
engineer-days with the test and CI updates; it is not possible for device
builds until every shipped target has the core, so the deletion step has
to either keep the C++ interpreter as a device-only build option (an
`#ifdef TOIT_CXX_INTERPRETER` around the files above, hosts without it) or
wait for the Xtensa toolchain.

## services-network-test: a real library bug

`ServiceProvider.uninstall` iterated over `_clients_` while
`ServiceManager_.close` removed each client from it (`_close_`). After
enough removals `Set.remove` shrinks and compacts the backing
(`shrink-if-needed_`). Format 1's HASH_DO intrinsic re-reads the backing
on every step and stops at its end ("We don't support this, but we also
don't want to crash", interpreter_core.cc), so it silently skipped the
clients that moved; format 2 has no HASH_DO and runs `Set.do`'s Toit loop,
whose bound was read before the iteration: OUT_OF_BOUNDS. Not a race; the
timing only decided how many clients were open at uninstall.

Reproduction (tests/services-uninstall-many-clients-test.toit, added):
open 5 or more clients to one provider, then `uninstall`. On upstream
master (format 1) `on-closed` runs for 3 of 5 clients ("Expected <5>, but
was <3>"): clients are left open, an upstream bug for a separate PR (the
fix is the one line in lib/system/services.toit: iterate over
`_clients_.to-list`). In format 2 the same test threw OUT_OF_BOUNDS in
`Set.do`. Both pass with the fix.

Related behavior difference, not changed: a program that removes from a
set or map inside its own `do` silently loses elements in format 1 and can
throw OUT_OF_BOUNDS in format 2 (Toit documents such modification as
unsupported).

## Requests to the core

None needed for this step. A nicety for the next one (not filed): the
launch verifier's message for a trusted-compiled program run untrusted
("unchecked opcode 106 in a program not in the unchecked mode") could say
"compile with --untrusted"; the C++ side can add that hint without the
core.

## Milestones

- M1 (bf521db9): the compiler's default is format 2 on builds with the
  core; the CMake cache variable `TOIT_BYTECODE_FORMAT` replaces
  `TOIT_SYSTEM_FORMAT2`; `--untrusted` for toit.compile (no twins,
  certificate); trusted compilation (twins) is the default and ships no
  certificate; devices and cross builds keep format 1; the sandbox tests
  compile their images without twins and the CLI tests write their
  snapshots with `toit.run --untrusted -w`.
- M2 (19150d80, and a follow-up keeping the line numbers): the
  services uninstall bug.
- M3 (71b2f071, and the optimization tests): toitp and the snapshot tools
  format-2 aware.
- M4: the untrusted suite against format 1, the firmware warning, the
  FORMAT-1-ONLY markers, -O2 and benchmark measurements, this document.

- M5 (1aba38f2, 85be00dc): `sandbox-integration` merged again (the
  contract table and grow_stack.render fixes); the verifier hints at
  `--untrusted` when a trusted-compiled program is launched untrusted.

## Gates (85be00dc)

Scripts in the artifacts directory (final.sh, suite.sh, bench.sh, o2.sh,
host32.sh); logs under suite/, bench/, o2/.

- ctest -j16, the new default (build/host, format 2 everywhere):
  1199/1202; failing only version and reader (not built) and
  udp-reuse-port-test (no multicast). services-network-test passes
  (tls-ubuntu-test, flaky, passed this run; it timed out in an earlier run).
- The same suite with `-DTOIT_BYTECODE_FORMAT=1` (build/host-f1, format 1
  everywhere): 1199/1202, the same three.
- The slow-configuration groups that inspect bytecodes or snapshots
  (optimizations, type_propagation, envelope, image, negative, pkg, cmake,
  ctest): 692/692 in both builds.
- verified/check.sh --tests: passed (spec 940, core 878 at both widths,
  audit, contracts, VeriFast, sandbox ctests 123/123). Before the M5 merge
  the contract table and grow_stack.render drifted (fixed on
  sandbox-integration by eb247dd9; not from this branch).
- Untrusted suite: 280 identical, the two known differences
  (program-name-test, set-map-remove-first-test).
- 32-bit host (build/host32, format 2 default): sandbox ctests 123/123.
- Classic ESP32 firmware builds (toit.bin 1,462,512 B, iram0.text 129,087
  B) with a format-1 system snapshot; installing a default-compiled
  snapshot into its envelope prints the warning.
- Benchmarks (callgrind in `Interpreter::run`, millions; `trs` the new
  default, `chk` the code untrusted programs run; recorded values from
  trusted-integration in parentheses): richards 1,075.3 (1,075.4),
  deltablue 758.8 (758.8), pystone 811.9 (812.0), json 1,314.5 (1,314.6),
  yaml 4,172.7 (4,173.1), strings 3,337.3 (3,337.3), RPC 412.7 (412.7),
  map-set 2,523.4 (2,523.4); checked richards 1,163.3 (1,163.3), RPC 425.4
  (425.4). C++ f1: richards 1,024.3, json 1,117.1. Not slower.
