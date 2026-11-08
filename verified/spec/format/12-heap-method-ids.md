# 12. Method ids from the heap and from block slots are checked

## Problem

`INVOKE_LAMBDA_TAIL` reads the method id and the captured values from a
`Lambda` object, `INVOKE_INITIALIZER_TAIL` the id from a
`LazyInitializer_`, and `INVOKE_BLOCK` from the block's slot. Toit code
writes those fields and slots, so the verifier cannot prove them (report
02, section 6.2). Format 1 also decided "array or single capture" by the
captured value's type (DESIGN.md item 13) and used the count without a
check, so a crafted lambda shifts the stack by an arbitrary amount.

## Alternatives

* A verifier-produced entry table and a binary search per lambda call
  (P2).
* Field-kind invariants for system classes in the verifier (report 02,
  option 1): ties the verifier to the core library's layout.
* Run-time checks on the method table (chosen; cheap with note 1).

## Decision

The method id must be a smi that indexes the method table, of kind lambda
(INVOKE_LAMBDA_TAIL), method with arity 0 (INVOKE_INITIALIZER_TAIL) or
block (INVOKE_BLOCK, TRY); otherwise the machine raises `INVALID_PROGRAM`.
A lambda's captured values are checked against the captured count in the
method's header: an array of exactly that length, or one non-array value
when the count is 1 (the library wraps a single captured array, so the
existing `lambda__` keeps working). Too few arguments raise
`CODE_INVOCATION_FAILED`.

## Spec and obligations

`block_target` and `captured` (20 lines). The verifier proves only what
it can see: `LOAD_METHOD` operands and the immutability of block slots
while referenced (which makes the INVOKE_BLOCK check redundant for
verified code). Proven: INVOKE_BLOCK and TRY with their checks.

## Cost

One bounds check and one kind compare per block, lambda or initializer
call (the header is loaded for the arity anyway); one length compare per
lambda call. The verifier no longer needs an entry table.
