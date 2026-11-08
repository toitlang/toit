# 9. Branches: forward offset 0 is illegal, targets stay in the method

## Problem

`BRANCH 0` jumps to itself without a preemption check (only backward
branches check), an uninterruptible loop. Format 1 branch targets are
only bounded by the whole bytecode array. `BRANCH_BACK`'s second operand
(the method's entry offset, for the preemption profiler) must be verified
or trusted (P9).

## Alternatives

* Keep offset 0 and add a preemption check to forward branches.
* Make offset 0 illegal (chosen); the compiler never emits it.
* For `BRANCH_BACK`: keep and verify the operand (P9's recommendation for
  format 1), or derive the method from the frame (chosen: format 2's
  frame stack has the method).

## Decision

A forward branch (BRANCH, BRANCH_IF_*) with offset 0 is stuck; the
verifier rejects it. All branch targets must lie inside the current
method's body. `BRANCH_BACK*` is 3 bytes (distance only).

## Spec and obligations

Two conditions in `op_branch`/`branch_to`; the verifier checks targets
against the method's instruction boundaries and stack maps.

## Cost

None at run time (the bound is a verifier obligation; a VM may check it
anyway at the cost of a compare per taken branch). 2 bytes saved per
backward branch.
