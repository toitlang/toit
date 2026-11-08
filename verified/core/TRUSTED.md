# Trusted base of the verified core

"Verified" in this crate means: every function inside `verus!` in
`src/exec.rs` is proven by Verus against the spec in `src/spec.rs`, with
no `assume`, `admit`, `assume_specification` or `#[verifier::external_body]`
outside the items listed here. Everything below is assumed, not proven. The
list must only shrink.

Check: `grep -rn "external_body\|assume\|admit\|external\b" src/` must show
only the items in this file.

## 1. Memory views (`src/view.rs`, `#[verifier::external_body]`)

The views are opaque structs holding a raw pointer and a length. Their ghost
content is an uninterpreted spec function (`view`). Each exec function below
has a body Verus does not see; its `requires`/`ensures` is the assumed
contract.

| Item | Assumed contract |
|---|---|
| `StackView` (struct) | Wraps `ptr[0..len)` of `usize` words. Ghost view: `Seq<usize>` of length `len`. Nobody else reads or writes this memory while the view exists. |
| `StackView::len(&self) -> r` | `ensures r == self@.len()` |
| `StackView::read(&self, i) -> r` | `requires i < self@.len()`; `ensures r == self@[i]` |
| `StackView::write(&mut self, i, v)` | `requires i < old(self)@.len()`; `ensures final(self)@ == old(self)@.update(i, v)` |
| `CodeView` (struct) | Wraps the immutable bytecodes `ptr[0..len)`. Ghost view: `Seq<u8>`. |
| `CodeView::len(&self) -> r` | `ensures r == self@.len()` |
| `CodeView::byte(&self, i) -> r` | `requires i < self@.len()`; `ensures r == self@[i]` |
| `DispatchView` (struct) | Wraps the immutable dispatch table `ptr[0..len)` of `i32`. Ghost view: `Seq<i32>`. |
| `DispatchView::len(&self) -> r` | `ensures r == self@.len()` |
| `DispatchView::at(&self, i) -> r` | `requires i < self@.len()`; `ensures r == self@[i]` |
| `RoomOracle` (struct) | Holds `limit_` and a pointer to `Interpreter::watermark_`. |
| `RoomOracle::has_room(&self, sp, h) -> r` | No contract (nondeterministic). Modelled in the spec as the `room` input of `spec_invoke_static`. Its answer affects only whether the C++ interpreter handles the call (stack growth, preemption); memory safety of the core never depends on it, because every push is bounds-checked against the stack view. |

The ghost contents (`view`) are declared `uninterp spec fn`: they carry no
assumption by themselves; the contracts above are what relate them to
memory.

`Env::code_base` (the address of the bytecodes, which return addresses are
relative to) is a plain value set by the FFI glue; the spec is stated in
terms of it and `entry` checks `code_base + code_len` does not overflow, so
it carries no assumption either.

Implicit assumptions behind the views:

- The ghost content of a view equals the memory content at the time of each
  call (no concurrent mutation). True because the interpreter thread owns the
  process stack while running, and bytecodes and dispatch table are
  immutable program data.
- `Object*` and `uword` are `usize`-sized; `std::atomic<Object**>` has the
  layout of `AtomicUsize` (true for x86-64 and RV64 GCC/Clang).

## 2. FFI glue (`src/ffi.rs`, not processed by Verus)

| Item | Assumption |
|---|---|
| `toit_vcore_run(state)` | Caller passes a valid `toit_vcore_state` whose fields describe: the process stack array `[limit_, base_)` (`stack_limit`, `stack_len`), indices `sp`/`try_sp` relative to `limit_`, the program's bytecodes and dispatch table, the frame marker, and `&watermark_`. The verified `entry` re-checks every index and length it relies on (`sp <= len`, `try_sp <= len`, size limits, no address overflow) and declines otherwise; the glue itself only constructs views and copies three words back. |
| `VcoreState` layout | Must match `toit_vcore_state` in `src/verified_core.h`. Machine-checked by the layout check (size and every field offset). |
| `toit_vcore_covers`, `toit_vcore_max_height` | Thin wrappers around verified functions (`covers_exec`, `method_max_height`), used only by the layout check. |
| `toit_vcore_layout_count/entry` | Export the constants of `src/layout.rs` by name for the layout check. |
| `panic_handler`, `rust_eh_personality` | Never reached: verified code has no panicking operations (overflow and bounds are proven), the trusted views do not panic. |

## 3. Layout constants (`src/layout.rs`)

Every constant is an assumption about the C++ VM. All are compared against
the C++ headers at build time by `verified/layout_check.cc` (CMake target
`toit_verified_core_layout`, which `toit_vm` depends on; also the ctest
`verified_core_layout`). Not checkable from headers, and therefore checked
against literals in the check program instead (review on change):

- `FRAME_MARKER_SLOT = 0`, `RETURN_ADDRESS_SLOT = 1`: the push order in
  `CALL_METHOD_WITH_RETURN_ADDRESS`.
- `SMI_LINK_*_INIT`: literals in the `LINK` handler. `SMI_LINK_REASON_INIT`
  (-1) is the "normal unwind" marker that the C++ `UNWIND` tests for.
- The non-local-return reason word `Smi::from(arity << 1)` (bit 0 clear
  means "return") and the try-block call shape (`[link words][block
  ref][frame]`) used by the unwinder.

## 4. The spec itself

`src/spec.rs` is the definition the handlers are proven against. That it
matches what `interpreter_run.cc` does is *not* proven; it is a reviewed
transcription, validated by running the VM's test suite with the core
enabled. Known, intended differences from the C++ handlers:

- Every C++ `ASSERT` and every unchecked memory access becomes a `Trap`
  (the hook FATALs) instead of undefined behavior.
- `NON_LOCAL_RETURN*` does not write the three temporary unwind words below
  the final stack pointer (dead slots).
- `NON_LOCAL_RETURN*` checks the frame marker on the "hit unwind protect"
  path too (C++ only ASSERTs it).

## 5. The C++ side

- `VERIFIED_CORE_HOOK` (`src/verified_core.h`) converts the interpreter's
  pointers to indices and back. Trusted.
- The C++ interpreter, GC, scheduler and everything else are trusted, as in
  the plan (07-verified-sandbox-plan.md). The core never runs across a GC
  point: none of the covered opcodes allocates, and the hook returns to C++
  before any opcode that can.
