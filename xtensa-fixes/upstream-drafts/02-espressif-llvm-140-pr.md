DRAFT, not sent. Target: a pull request on espressif/llvm-project
(release/esp_22.x; patch: patches/llvm-140/0001-*.patch), comment on
espressif/llvm-project#140 and esp-rs/rust#284. Upstream main has the same
code (XtensaFrameLowering.cpp lines 63 and 91-101 at the time of writing);
the patch applies there with trivial context changes.

---

Title: [Xtensa] Realign the windowed-ABI stack with MOVSP

Fixes #140 (esp-rs/rust#284).

For a stack object aligned above 32 bytes, `emitPrologue` realigned SP with
a plain `ADD` right after `ENTRY`. In the windowed ABI the caller's a0-a3
are spilled to the 16 bytes below SP; a window overflow or an interrupt
(ESP-IDF spills all windows on every interrupt) between `ENTRY` and the
`ADD` saves them below the old SP, and `RETW` reloads them from below the
new one. The same block had three more faults, all silent:

1. the misalignment was computed from the frame pointer (a7, still an
   incoming argument register at that point) instead of SP;
2. objects aligned to 32 bytes were not realigned at all (the guard was
   `MaxAlignment > 32`, SP is only 16-byte aligned), so an address
   computed with `or` from their known alignment was wrong;
3. incoming stack arguments were addressed from the realigned SP (or from
   a frame pointer set after the realignment), so they were read at a
   random offset:

       define i32 @f(i32 %a, ..., i32 %g, i32 %h) {   ; g, h on the stack
         %buf = alloca [64 x i8], align 64
         ...
       ; before: l32i a8, a1, 164 after `add.n a1, a1, a8`

The patch:

- realigns when the maximum alignment exceeds 16 bytes: computes
  `(SP + Align - 1) & -Align` in a scratch register and sets SP with
  `MOVSP`, which moves the base save area (through the Alloca exception)
  if the caller's registers were already spilled;
- gives a realigned frame a frame pointer that holds the incoming SP, set
  before the realignment: incoming stack arguments (fixed objects) are
  addressed from it, every other object from the realigned SP
  (`eliminateFrameIndex`), and the CFA (`FP + frame size`) is right again;
- reserves the call frame of a realigned function, so SP does not move
  around calls; a realigned function with a variable-sized object (which
  moves SP) is refused with a fatal error instead of being miscompiled.

Tests: `stack-realign-windowed.ll` (align 64 with MOVSP and nothing else
writing a1; align 32 realigned and the `or` address then correct; align 16
untouched; incoming stack arguments read from the frame pointer, with the
incoming a7 saved to a8 first and not clobbered by the scratch registers;
`frame-pointer=all`; a call with stack arguments from a realigned frame)
and `stack-realign-windowed-vla.ll` (the fatal error). Both fail on
release/esp_22.x and pass with the patch; CodeGen/Xtensa and MC/Xtensa
pass.

Not covered: the call0 ABI (its prologue has no realignment at all, so
over-aligned objects are under-aligned there too), and the debug-info
frame-index reference (`getFrameIndexReference` is not overridden, so DWARF
locations of locals in a realigned frame are still relative to the frame
pointer). Not tested on hardware: the spill race cannot be triggered
deterministically.

---

Comment for espressif/llvm-project#140 and esp-rs/rust#284:

A fix with lit tests: <PR link>. Besides `ADD` -> `MOVSP` and SP instead of
a7, it realigns align-32 objects (the guard was `> 32`) and addresses
incoming stack arguments from a frame pointer that keeps the incoming SP:
in a realigned frame they were read from the realigned SP, at a random
offset (`define i32 @f(i32 %a, ..., i32 %g, i32 %h)` with an align-64
local reads %g and %h wrong today).
