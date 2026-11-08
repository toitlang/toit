# 2. A separate frame stack

## Problem

Format 1 keeps the return address and the frame marker on the object
stack between a method's parameters and its locals (DESIGN.md item 3).
Every instruction that touches a slot must make sure it is not a frame
word; RETURN, the tail calls and the intrinsics carry or assume the frame
height and arity and re-check the frame words; a method can read and write
its caller's slots (`LOAD_LOCAL` with a large offset), and the spec had to
invent `RetAddr`/`FrameMarker` values with the rule that loading one is
stuck.

## Alternatives

* Keep the frame words, check them in RETURN (P5, "defensive unwinder")
  and have the verifier prove offsets never reach them.
* Frame-pointer-relative local addressing (locals indexed from the frame
  base, JVM style): cleaner, but every `LOAD_LOCAL`/`STORE_LOCAL` emitted
  by the compiler changes and the peephole optimizer's patterns with it.
* A separate frame stack, keeping sp-relative addressing (chosen).

## Decision

The state has a frame stack of `Frame { method, ret, base }`; `base` is
the object-stack index of the frame's first parameter. A call pushes a
frame whose base is the height minus the callee's arity; RETURN cuts the
object stack back to the base, pushes the result and pops the frame. The
object stack holds only values. Local addressing stays sp-relative (the
compiler only changes the parameter offsets: `FRAME_SIZE` becomes 0), but
every slot access is bounded by the frame: `has_slot(s, n)` is `n <
stack.len() - base`.

## Spec and obligations

`FrameWord`, `BadFrame` (for frame words) and the `RetAddr`/`FrameMarker`
values are gone from format 2. RETURN, RETURN_NULL and NON_LOCAL_RETURN
have no operands, so there is nothing to verify about them; the verifier
only proves that heights are consistent at every instruction, which gives
"no access below the frame base". The frame stack never contains data a
program wrote, so no frame-word integrity is needed. Spec: call/return are
25 lines (`call`, `return_from`), the frame/unwind family is 171 lines
against 156 in format 1 (which had no handler mechanics). Proven: calls,
returns, the unwinding loop (`x_call`, `x_return`, `x_unwind`).

## Cost

A call writes three words to the frame stack instead of two to the object
stack (the method index lets the VM find the method of any frame without
scanning for a header); returns no longer decode operands. Preemption and
stack overflow checks move to the frame stack (one more limit). The frame
stack needs its own region: on ESP32 a task's stack would be split in two
growing ends of one allocation. Estimated neutral (+-2 %) on calls.
