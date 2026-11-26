DRAFT, not sent. Target: a pull request on espressif/llvm-project
(release/esp_22.x; patch: patches/llvm-142/0001-*.patch), comment on
espressif/llvm-project#142 and esp-rs/rust#286. Upstream main has the same
`Align(4)` and the same CALLSEQ_END; the patch applies there too (the
regenerated tests need regenerating against main).

---

Title: [Xtensa] Keep the stack pointer 16-byte aligned at calls

Fixes #142 (esp-rs/rust#286).

The Xtensa ABIs keep SP 16-byte aligned (GCC: `STACK_BOUNDARY 128`) and
the prologue rounds every frame to 16 bytes, but `XtensaFrameLowering`
declared a stack alignment of 4. When the call frame is not reserved (a
frame pointer or a variable-sized object), a call with stack arguments
moved SP by their size rounded to 4, so the callee ran with SP at 4, 8 or
12 mod 16, and an address it computed with `or` from the known alignment
of an 8- or 16-byte aligned local was wrong (the heapless::String case of
the report).

The patch declares a stack alignment (and transient alignment) of 16. It
also fixes `LowerCall`, whose `CALLSEQ_END` released the unrounded size
while `CALLSEQ_START` reserved the rounded one: equal while the alignment
was 4, a drift of SP by up to 12 bytes per call otherwise (the machine
verifier reports the mismatch).

Consequences: variable-sized objects are rounded to 16 bytes, and call0
frames are multiples of 16 bytes as with GCC. 17 CodeGen tests change
only in call0 frame sizes and spill offsets (13 regenerated with
update_llc_test_checks.py, 4 edited by hand: call.ll, stack-access.ll,
dynamic-alloc.ll, setcc.ll).

Test: `call-frame-align.ll` (three stack words with `frame-pointer=all`:
SP moves by 16 and back by 16; a variable-sized object plus one stack word:
the same; the size of a variable-sized object rounded to 16). It fails on
release/esp_22.x and passes with the patch; CodeGen/Xtensa and MC/Xtensa
pass (128/128 with this test).

---

Comment for espressif/llvm-project#142 and esp-rs/rust#286:

A fix with a lit test: <PR link>. `Align(16)` as suggested, plus
`CALLSEQ_END` in `LowerCall`, which released the unrounded stack-argument
size (with a 16-byte alignment SP would otherwise drift by up to 12 bytes
per call). call0 frames become multiples of 16 bytes, as with GCC.
