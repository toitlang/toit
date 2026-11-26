DRAFT, not sent. Target: a pull request on espressif/llvm-project
(branch release/esp_22.x; patch: patches/llvm-139/0001-*.patch), plus a
short comment on espressif/llvm-project#139 and esp-rs/rust#283 pointing to
it. The account and the decision to send are the project owner's.

---

Title: [Xtensa] Do not read memory at a literal's value for narrowed literal loads

Fixes #139 (esp-rs/rust#283).

Since LLVM 21, `LowerGlobalAddress` (and the block-address, jump-table,
callee and TLS lowerings) return a generic `load` of an
`XtensaISD::PCREL_WRAPPER`, so the wrapper is the address of a literal.
When only part of the loaded value is used (`(unsigned)&g & 0xff`,
`(unsigned)&g >> 16`, `((unsigned)&g >> 24) == 0x3f`, a 16-bit store of the
upper half), DAGCombine narrows the load (`ReduceLoadWidth`, also from
`SimplifySetCC`), which leaves the wrapper as the address operand of an
L8UI/L16UI/L16SI. The fallback pattern
`(Xtensa_pcrel_wrapper tconstpool) -> L32R`, added in 39a59933 for
aggregate constants, selects that address as the literal's *value*, so the
narrowed load reads memory at the global (or function, or basic block)
instead of computing bits of its address. No diagnostic.

The patch:

- overrides `shouldReduceLoadWidth` to never narrow a load whose base is a
  `PCREL_WRAPPER` (a literal can only be read whole, by L32R); the
  extension is done on the loaded value (`and`, `extui`, `srli`, `srai`);
- makes `LowerConstantPool` return the load of the literal that holds the
  address of an aggregate or vector constant (the global it creates), so
  `ISD::ConstantPool` means the data's address as on every other target;
- removes the bare-wrapper fallback pattern and the two
  `load (add s, wrapper)` patterns (i32 and f32), which assumed the
  opposite meaning. Any remaining path that uses a literal other than
  through a full-width load is now a selection error instead of wrong code.

Test: `llvm/test/CodeGen/Xtensa/constantpool-narrow-load.ll` (low byte,
byte 1, upper half signed and unsigned, a 16-bit store of the upper half,
a compare of the top byte, a function's and a block's address, plus a real
byte load from a global and an immediate from the literal pool, which must
not change). It fails on release/esp_22.x (esp-22.1.4_20260825 sources,
3eeb0284 as pinned by esp-rs/rust 1.99.0.0) and passes with the patch.
`constantpool_aggregate.ll` (the case 39a59933 fixed) passes unchanged.
CodeGen/Xtensa and MC/Xtensa: 128/128 pass.

Effect on real code: compiled the bitcode of a 100 KB no_std Rust library
(Toit's verified interpreter and verifier, five configurations: opt 3, s,
z, with and without fat LTO) with and without the patch: the only
differences are commuted operands of an `add` where a select of two FP
constants indexes its aggregate constant (in compiler_builtins' `floorf`
and similar), with identical semantics.

Upstream (llvm/llvm-project main) has no fallback pattern, so there the
same narrowing is the `Cannot select: XtensaISD::PCREL_WRAPPER` of
llvm/llvm-project#227826; the `shouldReduceLoadWidth` part applies there
as is. It may also be what stops upstream Rust nightly from compiling
`compiler_builtins` for Xtensa (`Cannot select: XtensaISD::PCREL_WRAPPER`),
which we saw but did not reduce.

---

Comment for espressif/llvm-project#139 and esp-rs/rust#283 (short):

A fix with a lit test: <PR link>. It keeps DAGCombine from narrowing loads
from the literal pool (`shouldReduceLoadWidth`), makes `LowerConstantPool`
load the address of an aggregate constant explicitly, and drops the
fallback pattern from 39a59933. The six cases of the report compile to
`l32r` plus `and`/`extui`/`srli`/`srai` again; `constantpool_aggregate.ll`
is unchanged.
