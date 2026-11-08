# 3. Block references as (frame, slot), no salt

## Problem

A format-1 block reference is the smi `base - pointer + BLOCK_SALT`
(DESIGN.md item 2). The salt is obfuscation, not a check: any smi is a
pointer into the stack. LOAD_OUTER/STORE_OUTER/LOAD_OUTER_BLOCK index
backwards from it with no bound, and NON_LOCAL_RETURN/NON_LOCAL_BRANCH
compute the target frame from the reference plus height and arity
operands, which the verifier has to match against the outer frame's
layout.

## Alternatives

* Keep salted smis and let the verifier track block kinds (report 02,
  section 6.1).
* A unique activation id per frame in the reference, to detect stale
  references at run time (a real salt): needs an id per frame and a
  compare per use; stale references are what the verifier excludes
  anyway.
* `(frame index, slot)` with frame-relative bounds (chosen).

## Decision

`Value::BlockRef(frame, slot)`. LOAD_BLOCK makes one to a slot of the
current frame, LOAD_OUTER_BLOCK to a slot further down in the referenced
frame, TRY to the try block's slot. A reference is valid (`ref_ok`) if the
frame is live and the slot lies inside that frame (`base <= slot <` the
next frame's base). LOAD_OUTER/STORE_OUTER/LOAD_OUTER_BLOCK `k` address
`slot - k`, which must stay inside the frame. NON_LOCAL_RETURN has no
operands (the frame is in the reference); NON_LOCAL_BRANCH keeps the
height operand and encodes the target relative to the entry of the
frame's method. The block's method id in the slot is checked when the
block is invoked (note 12).

## Spec and obligations

The VM may represent the reference as a tagged smi `frame << k | slot -
base` (the verifier keeps it from being used as an integer); the spec
keeps the pair. Validity is checked in the spec (`ref_ok`, stuck
otherwise): the verifier proves references never outlive their frame and
are never left pointing at a popped or overwritten slot (block slots are
immutable while referenced; references are never stored in the heap,
returned or passed to primitives). With those, the run-time `ref_ok`
check can be omitted by the VM. Blocks family: 131 spec lines (125 in
format 1). All block operations are proven (`x_load_block`,
`x_load_outer`, `x_store_outer`, `x_load_outer_block`, `x_invoke_block`,
`x_non_local_return`, `x_non_local_branch`).

## Cost

Same as format 1 for LOAD_OUTER (a subtraction from the frame's base
instead of from the stack base); NON_LOCAL_RETURN saves its operand byte.
The salt computation disappears. Neutral.
