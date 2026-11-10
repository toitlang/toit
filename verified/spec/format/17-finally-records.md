# 17. Unwinding without a heap token: finally records

Replaces the heap token of note 4 (request R1, PHASE4-REQUESTS.md).

## Problem

Entering finally code with a pending unwinding allocated a token object
holding the `Unwind`. A non-local `return` out of a monitor method (the
compiler wraps monitor bodies in try/finally) therefore allocated on every
call (tests/channel-retention-test.toit fails in format 2), and under heap
exhaustion the allocation could fail, so the exception skipped the finally
code.

## Alternatives

* The request as written: the pending unwinding in the handler's frame
  record, one record per frame, a `break` out of finally code leaving a
  stale record that the next TRY of the frame overwrites. Unsound as
  stated: finally code may itself contain a try/finally (inline, same
  frame). If the inner finally is entered by an unwinding while the outer
  token is live, the inner record overwrites the outer one; after a
  `break` out of the inner finally, or a non-local branch that ends inside
  the outer finally code, the outer UNWIND resumes the inner unwinding
  (wrong control flow, a branch above the live stack). Example: `try:
  [1].do: return 1 finally: (while true: (try: [2].do: break finally: ...)
  ...)` (tests/toit/finally_records.toit).
* Encode the unwinding in the token slots themselves (they are
  unforgeable): a branch needs frame, bci and height, more than one smi
  holds on 32-bit targets; more slots would change the compiler's finally
  layout.
* A stack of records next to the handler stack (chosen).

## Decision

The state gets `fins: Seq<Fin>` next to the handlers, and a suspended
task's stack object keeps them too (`Body::Stack2` gains the field).

* `Fin { frame, height, resume }`: the frame running the finally code, the
  height of its three slots (value, token, reason), and what it resumes
  (`Resume::Throw`, `Return(frame)`, `Branch(frame, bci, height)`, i.e.
  the `Unwind` without its value).
* Entering finally code with an unwinding pops the handler and pushes a
  record in its place: no allocation, and in the machine the record can
  reuse the handler's slot (the handler is the newest entry of both
  stacks at that point). The finally code's slots are the value (the
  exception or the return value, null for a branch), the token (the smi
  index of the record) and the reason (-2 for an exception, -1 otherwise).
  A normal completion still pushes null, null, -1.
* `UNWIND` with a smi token `k` checks that record `k` exists, belongs to
  the current frame and has its token slot where the token is
  (`fin_matches`), drops records `k` and above (the ones above are stale:
  their token slots were popped), and resumes the record's unwinding with
  the value slot's value. Anything else is `Stuck(NotUnwind)`; the
  verifier excludes it. The verifier's UNWIND rule now also requires the
  value slot to be a value.
* Popping a frame (return, unwinding, tail call) drops its records
  (`cut_fins(fins, top, 0)`; records are ordered by frame, so they are at
  the end).
* `TRY` at height `H` first drops the frame's trailing records whose
  token slot is at `H` or above (`cut_fins(fins, top, H - 1)`): no live
  token sits there. This bounds the records of a frame by its height: a
  loop whose finally code `break`s out during an unwinding reuses the
  record slot instead of growing the stack.

The value slot change is visible to Toit code: `finally: | is-exception
value |` now sees the return value of a non-local return instead of null,
which is what format 1 does (its LINK result slot); the compiler is
unchanged.

## Spec and obligations

The invariant replaces the token's heap object by the record: a `Token`
slot holds null or the index of a record of its own frame whose token slot
it is and whose unwinding can complete (`fin_ok`, `pending_ok` over
`Resume`); `fins_ok` keeps the records in live frames, ordered by frame
and height, and below the height of their frame's active handler (so the
record entering a finally adds stays ordered). Ordering is what makes the
truncations safe: a live token's record is never above a record that is
dropped. `Body::Pending` and `prim_heap_ok`'s clause about unwinding
tokens are gone. Proven: TRY, UNWIND, THROW, RETURN, the unwinding loop,
tail calls, task switching (records saved and restored).

## Cost

No allocation on any unwinding; entering a finally code writes one record
(three words plus the frame index) instead of allocating five words. TRY
gains a compare against the newest record (usually none). UNWIND checks
two words of the record.
