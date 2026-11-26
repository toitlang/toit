DRAFT, not sent. Two parts for esp-rs/rust#278.

(1) LLVM: the byval rounding is llvm/llvm-project#228365 (by the reporter,
approved 2026-11-02, not merged). For the Espressif fork the same one-line
change plus a test is patches/llvm-278-byval/0001-*.patch
(`calling-conv-byval-odd-size.ll`; the stock compiler fails the machine
verifier on it). Suggested comment on espressif/llvm-project (no issue
exists there; could go on esp-rs/rust#278 instead):

  The LLVM half of esp-rs/rust#278 (llvm/llvm-project#228365) applies to
  release/esp_22.x unchanged; with it a 5-7 byte byval argument occupies
  two words. Patch and test: <link>.

(2) rustc: patches/rustc-278.patch (compiler/rustc_target/src/callconv/
xtensa.rs at esp-1.99.0.0). Not built: we did not build rustc. A scalar
that does not fit in a2-a7 is no longer passed `byval` but as a direct
argument extended to 32 bits (`extend_integer_width_to(32)`), which LLVM
places on the stack as a whole, extended word (the fork's LLVM already
does this for clang's `i16 zeroext`: `s32i` of the extended value).
Aggregates keep `pass_by_stack_offset` and rely on (1) for odd sizes.

Suggested PR text for esp-rs/rust:

  Title: Xtensa: pass integer arguments on the stack as extended words

  Fixes #278. An integer narrower than 32 bits that does not fit in the
  six argument registers was passed byval, so only its own bytes were
  stored (s8i/s16i) and the rest of the stack word kept garbage; the Xtensa
  ABI (ISA RM 8.1.4) requires the whole word, zero- or sign-extended, and
  GCC-compiled callees read it with l32i. Integers are now direct arguments
  extended to 32 bits, as in registers; LLVM puts them on the stack itself.
  Aggregates stay byval and need llvm/llvm-project#228365 for sizes that
  are not a multiple of 4.

  Tested: <to be filled after a rustc build: the probe from #278 under
  QEMU, the esp-nn signature from the issue>.
