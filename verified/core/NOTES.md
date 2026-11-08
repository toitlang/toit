# Verified core, Phase 0 spike: notes

Phase 0, part 1 of `07-verified-sandbox-plan.md`: a Verus-verified Rust
core that executes a handful of opcodes inside the existing C++ VM.

## What is here

| Path | Role |
|---|---|
| `src/spec.rs` | Abstract machine: state = stack words (`Seq<usize>`), `sp`, `try_sp`, `bcp` as indices; one spec function per opcode; total `spec_step` with `Next`/`Fallback`/`Trap`; `spec_run` for multi-step runs. |
| `src/exec.rs` | Verified handlers. Each `ensures refines(r, spec_xxx(cfg, old@), old@, final@)`. `step` refines `spec_step`; `run` (bounded loop) refines `spec_run`; `entry` validates FFI inputs. |
| `src/view.rs` | TRUSTED raw-memory views (`StackView`, `CodeView`, `DispatchView`, `RoomOracle`), 12 `external_body` items. |
| `src/layout.rs` | Every constant assumed about the C++ VM. |
| `src/ffi.rs` | TRUSTED C ABI glue; exports constants for the layout check. |
| `../layout_check.cc` | Build-time layout contract check (72 entries + behavioral checks). |
| `../../src/verified_core.h` | C++ side: FFI struct, `VERIFIED_CORE_HOOK()`. |
| `TRUSTED.md` | The trusted base, item by item. |

Covered opcodes: `LOAD_LOCAL`, `LOAD_LOCAL_WIDE`, `LOAD_LOCAL_0..5`,
`STORE_LOCAL`, `POP`, `POP_1`, `LOAD_SMI_U8`, `INVOKE_STATIC`, `RETURN`,
`LOAD_OUTER`, `STORE_OUTER`, `NON_LOCAL_RETURN`, `NON_LOCAL_RETURN_WIDE`,
`LINK`, `UNLINK`. `BRANCH*` were not needed as substitutes.

## Decisions

- **Hook at dispatch time.** `DISPATCH` in `interpreter_run.cc` calls
  `VERIFIED_CORE_HOOK()` (3-line change). If the next opcode is covered, the
  hook marshals `sp`, `try_sp_`, `bcp`, the stack bounds, bytecodes,
  dispatch table, frame marker and `&watermark_` into a struct and calls
  `toit_vcore_run`, which runs covered opcodes until an uncovered one (at
  most 1024 per call). The C++ handlers for covered opcodes are untouched and
  still run whenever the core declines.
- **Indices, not pointers, in the spec.** The stack is the stack object's
  array `[limit_, base_)`; `sp`, `try_sp` are indices. Return addresses stay
  absolute (`code_base + bci`) because C++ code reads them.
- **Total spec with explicit `Trap`.** Every C++ `ASSERT` and every
  unchecked access the C++ handler relies on (local index inside the stack,
  block reference designates a live slot, frame marker present, return
  address inside the bytecodes, dispatch entry inside the bytecodes, try
  chain value in range) is a runtime check; on failure the hook FATALs. This
  makes memory safety of the core unconditional (no precondition on the
  program), at the cost of a few compares per opcode.
- **`Fallback` for runtime services.** Calls that fail the watermark check
  (stack growth, preemption), `POP` in `preempt_a_lot` mode, `Flags::trace`,
  and `TOIT_CHECK_PROPAGATED_TYPES` builds go to C++.
- **Words are `usize`, unsigned.** Block references and try-chain values
  are non-negative smis in practice; the core requires that and traps
  otherwise, avoiding signed shifts. Negative constant smis pushed by `LINK`
  are precomputed constants checked against `Smi::from` by the layout check.
- **no_std staticlib** built with plain `cargo build --release` (vstd from
  crates.io, `default-features = false`). Verification is a separate step
  (`cargo verus verify`, CMake target `verified_core_verify`, ctest
  `verified_core_verify`). The linked code is the verified source compiled
  by rustc; Verus does not need to be installed to build the VM.
- **CMake option `TOIT_VERIFIED_CORE`**: default ON for native 64-bit host
  builds, OFF for embedded/cross; silently (with a warning) OFF when cargo is
  missing. `toit_vm` depends on the layout check target, so a mismatch fails
  the build.

## Results

- Verus: `verus --crate-type=lib --cfg toit_vcore_hosted src/lib.rs --time`
  reports `79 verified, 0 errors`, total 1.4 s (SMT 0.56 s, 4 threads;
  1.5 s single-threaded). `cargo verus verify`: 1.6 s incremental; the first
  run also verifies vstd as a dependency (~30-60 s, once per target dir).
  Zero `assume`/`admit`.
- Hello world runs. Mutation experiments (make the core trap only on the
  direct-return path of `NON_LOCAL_RETURN`; separately only on its "hit
  unwind protect" path; separately on `STORE_OUTER`) each abort hello world,
  so these paths are on hello world's path (system code uses blocks and
  `try`/`finally`).
- Instruction mix (temporary `-DTOIT_VERIFIED_CORE_STATS` build): hello world
  app process 30,379 core / 33,334 C++ instructions (48% in the core),
  15,363 core calls (about 2 instructions per call). A fib/blocks benchmark:
  54%, 1.7 instructions per call.
- Cost: the benchmark (`fib 30` and a block-heavy loop) is about 4x slower
  than the C++-only build (fib 142 ms vs 28-41 ms; blocks 92 ms vs 23 ms).
  Expected: one non-inlined FFI call with a 14-word struct per ~2
  instructions, plus runtime checks. Not optimized.
- Tests: all 25 block/non-local/try/lambda/exception tests pass; full ctest
  suite 1055/1058 (the 3 failures: `version` and `reader` are not built in
  this configuration, `udp-reuse-port-test` fails identically on the
  C++-only build: no multicast in the sandbox).
- Layout check: mutating `BLOCK_SALT` or `METHOD_KIND_HEIGHT_OFFSET` in
  `layout.rs` fails the build with a precise message.

## What Verus could not express, and the workarounds

1. **C++-owned memory.** Verus cannot reason about memory it did not
   allocate without a trusted source of permissions. `vstd::raw_ptr`
   `PointsTo` tokens would let the view bodies be verified, but the tokens
   for C++ memory would themselves be minted by a trusted function, so the
   trust only moves. Workaround: opaque `external_body` views with ghost
   `Seq` contents and small contracts (TRUSTED.md).
2. **Environment nondeterminism.** The watermark is an atomic written by
   other threads (preemption) and by stack growth. It cannot be a ghost
   value of the state. Workaround: an oracle with no contract; the spec
   takes the oracle's answer as an input (`room`), and the handler returns
   it as a `Ghost<bool>` so the postcondition can name it. `run` returns the
   ghost sequence of oracle answers.
3. **The C++ semantics.** The spec is a transcription of
   `interpreter_run.cc`; Verus cannot check it against C++. Validation is by
   testing (VM test suite with the core enabled, mutation experiments).
   Phase 2's differential spec-vs-VM testing is the real fix.
4. **Layout constants.** Verus cannot read C++ headers. Workaround: one
   module of named constants, exported by name over FFI, compared by a C++
   program that includes the headers. Private constants (Method header
   offsets) are checked behaviorally (Rust `max_height` vs
   `Method::max_height` for all 256 header bytes). Some facts have no named
   C++ constant at all (frame slot order, `LINK` literals, unwind reason
   encoding); they are compared against literals and listed in TRUSTED.md.
5. **Mutable references.** This Verus version requires `final(x)` for the
   post-state of `&mut` parameters in `ensures`; facts about mutated
   variables are dropped at loop heads, so `run` restates `s0 == old(st)@`
   in its invariant.
6. **Two builds of vstd.** `cargo verus` uses the crates.io `vstd`
   (`no_std` here), direct `verus` uses the bundled `std` one; the
   `panic_handler` is gated behind `cfg(toit_vcore_hosted)` so both work.
7. **Frames as an invariant.** With a flat word stack, "this word is a frame
   marker" cannot be an inductive invariant: C++ steps between core steps
   can change anything. Workaround: dynamic checks. No frame-integrity
   theorem is proven; that needs the separate frame stack planned for
   Phase 2.

## Findings about the hybrid boundary (for Phase 4)

- **No inductive invariants across the boundary.** Every core entry must
  re-validate its inputs (`entry`) and every opcode must check what it
  relies on, because interleaved C++ handlers can establish nothing the
  verifier knows about. The core can prove per-step memory safety and
  refinement, not "the frame chain stays well formed". Phase 4 should move
  whole execution (all opcodes) into the core, not per-opcode islands.
- **Granularity kills performance.** About 2 instructions per crossing and
  a 4x slowdown. A mixed core needs either whole-method or whole-process
  ownership, or an inlinable boundary (LTO across C++/Rust, passing
  `sp`/`bcp` in registers).
- **Stack growth moves the stack.** `handle_stack_overflow` may reallocate
  the stack object; a core that calls into it (instead of falling back)
  must drop and re-create its `StackView` and treat all indices as relative
  to the new `limit_`. That is a GC-like point and belongs in the FFI
  contract with "invalidates views" semantics.
- **The unwinder is a cross-language protocol.** `NON_LOCAL_RETURN` did not
  need the whole unwinder: it performs the first unwind step (return to the
  target frame, or simulate a return from the innermost try-block call and
  write the link words). The C++ `UNWIND` then consumes those link words.
  The reason encoding (`-1` normal, `-2` exception, `arity << 1` return,
  `bci << 1 | 1` branch), the link slot layout and the try-block call shape
  `[link words][block ref][frame]` are implicit in C++ and must become a
  written contract (or disappear with the Phase 2 format).
- **try_sp_ can be null** before the first `load_stack`; the hook relies on
  the core's range check to decline in that case.
- **Program data is trusted by C++ but checked by the core.** Dispatch table
  entries, method header offsets and return addresses are validated per
  use. Phase 3's verifier should let these checks become proof obligations;
  until then they are cheap compared to the crossing cost.
- **No GC point inside the core.** None of the covered opcodes allocates,
  and everything that might (stack growth, preemption) falls back. Keeping
  this property in Phase 4 requires an explicit "may GC" effect on FFI
  calls; Verus can express it as a ghost token consumed by such calls.
