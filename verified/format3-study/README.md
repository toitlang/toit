<!-- Copyright (C) 2026 Toit contributors. -->
# Format-3 study tooling (branch study/format3)

Host-only tooling of the format-3 / certificate-v2 design study. The
write-up, all measurements and the recommendation are in
`/home/flo/work/opentoit-sandbox-artifacts/format3-study/README.md`.

Nothing here is built by the VM, linked into a device, or an input of the
verification epoch (`verified/verification-epoch.cmake` hashes
`verified/spec/src`, `verified/vmverify/src` and a few core and C++ files,
not this directory); the escape-hatch audit does not scan it (it is not one
of the audited crates). The only change outside this directory is an
opt-in trace format in `src/interpreter_v2.cc` (`TOIT_V2_TRACE_PROCESS`:
debug builds' `-Xtrace` lines also name the process and its program; the
default output is unchanged).

## f3study (Rust)

    cargo build --release --target-dir ../../build/f3study

| Command | What |
|---|---|
| `f3study static TABLES...` | static statistics: methods, sizes, opcode histogram, operand widths, calls, try, literals, static pairs |
| `f3study trace TABLES [TOP]` | dynamic statistics of a `-Xtrace` stream on stdin (segments between `OPB name` / `OPB -` lines): opcodes, classes, pairs, triples, call sites and their targets, primitives and their failures, branches, hottest methods |
| `f3study cert TABLES...` | certificate v1 sizes by section, mapped instructions, branch targets, joins, stream sizes of other map placements, per-method max heights |
| `f3study verify MODE RUNS TABLES...` | one checker: `shipped` (today's proven `cert::verify_shipped`), `fused`, `fused-inc`, `fused-opt` (the **unproved** single-pass prototypes, `src/fused.rs`) |
| `f3study cross TABLES [N]` | differential test: the prototypes against `verify_shipped` on N mutated certificates and N mutated method bodies |
| `f3study phases TABLES` | the loader conversion (`from_vm::convert`) and the heap check alone |
| `f3study probe TABLES BCI VALUE` | one code mutation, both verdicts |

TABLES are `toit.run --verify --emit-canonical=X.tables` files. Programs
compiled as trusted (unchecked twins) need `F3STUDY_TRUSTED=1`.

`src/fused.rs` is a prototype for measurement: it reuses the proven
checker's per-instruction functions but its driver is plain, unproved
Rust. It must not be used to accept programs.

## Scripts (`scripts/`, copies of the artifact directory's)

`make-tables.sh` (compile and dump the programs), `cg-verify.sh`
(callgrind of the checkers), `cgrun.sh` and `cgfuncs.sh` (callgrind of the
run-time benchmarks, slow paths by function), `trace.sh` (debug build,
`-Xtrace` piped into `f3study trace`), `pairs-mean.sh` (equal-weight means
over the benchmarks). They expect the artifact directory's `progs/`
(`progs/host`, `progs/suite`); `progs/` here has the two programs the study
added (`cgbench.toit`, `taskbench-opb.toit`).
