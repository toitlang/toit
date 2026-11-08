# 8. A terminator after every method body

## Problem

A format-1 method body may end after a call to a method the compiler
knows does not return, or after a monitor's `locked_` call (report 02,
P1). If the callee returns anyway, execution runs into the next method's
header. The verifier cannot prove non-return of library code.

## Alternatives

* `LOAD_NULL; THROW` after such bodies (P1, 2-3 bytes per site).
* A 1-byte `UNREACHABLE` opcode that is fatal if executed.
* Make the semantics bound execution to the method body (chosen,
  together with the first alternative).

## Decision

Every format-2 method body ends in a terminator: RETURN, RETURN_NULL,
THROW, BRANCH, BRANCH_BACK, a tail call, NON_LOCAL_RETURN or
NON_LOCAL_BRANCH. The compiler appends `LOAD_NULL; THROW` when the body
could fall off the end (`ByteGen::terminate_body`). Independently, the
spec fetches instructions only inside the current frame's method
(`instruction_ok` uses the method table's `end`), so falling off the end
is a stuck state the verifier excludes by the terminator rule, and a VM
that does not check gets a defined result.

## Spec and obligations

The verifier checks the last instruction (`method_ok`); no proof about
library behavior. The interpreter's loader checks it for every loaded
program (it holds for all 418 test programs).

## Cost

2 bytes per unterminated body (the interface stubs of note 10 and calls
to `throw`-like helpers); never executed in correct programs.
