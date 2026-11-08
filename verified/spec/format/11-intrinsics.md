# 11. The intrinsics are removed (added candidate)

## Problem

INTRINSIC_SMI_REPEAT, INTRINSIC_ARRAY_DO, INTRINSIC_HASH_FIND and
INTRINSIC_HASH_DO are re-entrant state machines: they run as the body of a
method, keep their state in stack slots at fixed offsets past the frame
words, call blocks and re-execute themselves when the block returns
(DESIGN.md item 7). They read fields of Toit-level collections and trust
them (P6). In the format-1 spec they are 428 lines, the largest single
family, and INTRINSIC_HASH_FIND hid a bug (the rebuild argument, fixed in
c5d7adec).

## Alternatives

* Keep them, with frame-relative state and checked collection fields.
* Remove them (chosen).

## Decision

Format 2 has no intrinsics. The compiler generates `repeat` and `do_` as
bytecode loops (counter in a local, INVOKE_LT, INVOKE_BLOCK with the
index or element, INVOKE_ADD, BRANCH_BACK; `ByteGen::generate_intrinsic_v2`),
and for `hash-find` and `hash-do` it lets the Toit implementation in the
primitive's failure block run (which ESP32 builds without the IRAM
helpers already use). The core library is unchanged.

## Spec and obligations

-428 spec lines (and the fuel-bounded `hash_do`/`hash_find_loop` helpers
that needed `OutOfFuel` stuck states). No verifier obligation about
intrinsic frames. The loops consist of ordinary, proven instructions.

## Cost

The main cost of format 2: +13.9 % executed instructions on the test suite
(72.8 M -> 83.0 M; 1.09 M intrinsic dispatches replaced). The bytecode
loop of `repeat` executes about 12 instructions per iteration against one
re-dispatch of the intrinsic; `hash-find` in Toit makes map-heavy
programs execute more instructions (`tests/toit/maps.toit`: 106 k -> 170 k
instructions, +61 %). Instructions
are cheap compared to the block calls they surround, so the time cost is
lower than the instruction count suggests; if a benchmark shows it, a
verified `REPEAT` instruction with frame-relative state can come back
(about 40 spec lines) without reintroducing the hash state machines.
