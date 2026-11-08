# 6. Tail calls replace the top frame

## Problem

Format 1's INVOKE_STATIC_TAIL `d h a` and INVOKE_INITIALIZER_TAIL `h a`
carry the current method's expression height and arity; the VM moves the
arguments over the frame words and the parameters, trusting both
operands. INVOKE_LAMBDA_TAIL `k` addresses the receiver past the frame
words. Each has to re-check the frame words in the spec.

## Alternatives

* Keep the operands and verify them against the abstract height and the
  method's arity.
* Replace the top frame (chosen).

## Decision

INVOKE_STATIC_TAIL `d` (3 bytes), INVOKE_INITIALIZER_TAIL and
INVOKE_LAMBDA_TAIL (1 byte): the arguments (the top `arity(target)` slots;
for lambdas the frame's parameters after the receiver plus the captured
values) replace the frame's slots from its base, the frame's method
becomes the target, its return address stays. A frame with an active
handler cannot tail-call (it is suspended in TRY; stuck if it happened).
The receiver check of note 7 applies to tail calls as to calls.

## Spec and obligations

`replace_frame` (12 lines) is shared by the three; no operand to verify,
no frame words to check. The verifier proves that block references of the
current frame are not passed to a tail call (they would dangle once the
frame is replaced) and that INVOKE_LAMBDA_TAIL runs on an otherwise empty
frame. Proven: INVOKE_STATIC_TAIL (`x_invoke_static_tail`,
`x_replace_frame`).

## Cost

The same copy of the arguments as format 1; saves 2 operand bytes per
static tail call and 2 per initializer stub.
