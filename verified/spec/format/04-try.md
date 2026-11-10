# 4. One TRY instruction with a handler stack and unwinding tokens

(Since note 17 the token is the smi index of a finally record instead of a
heap object, and the value slot also holds a non-local return's value.)

## Problem

A format-1 try/finally is `LINK; LOAD_BLOCK; INVOKE_BLOCK 1; POP_1;
UNLINK` followed by the finally code and `UNWIND` (DESIGN.md item 4). LINK
pushes four words of mixed meaning (result, target, reason, chain); the
unwinder relies on the exact layout `[link words][block ref][frame]`; the
reason slot is also the Toit local `is-exception` and the program can
overwrite it and so redirect the unwinding; reasons overload smis (-1, -2,
`arity << 1`, `bci << 1 | 1`) and are truncated to 32 bits.

## Alternatives

* Keep the sequence and pattern-match it in the verifier (report 02,
  section 4.4).
* P8's `TRY_BLOCK k` replacing the sequence but keeping the four words.
* A handler record in the frame stack with the pending unwinding next to
  it: a `break` out of finally code (allowed in Toit) leaves a stale
  record, and cleaning it up costs a check on every branch.
* A handler stack plus the pending unwinding in a heap token in the
  finally's own stack slots (chosen): popping the slots drops the
  unwinding, so a `break` out of finally code needs nothing.

## Decision

`TRY` (1 byte): the try block's method is the top slot. TRY pushes
`Handler { frame, height, bci + 1 }` and calls the block with a reference
to that slot. When the block returns into the frame of an active handler,
or an unwinding reaches it, the handler is popped and the finally code
starts with three slots: the exception (or null), a token and the reason
(-2 for an exception, -1 otherwise) — the slots format 1's compiler
already maps `is-exception` and `exception` to, so the compiler only
replaces the five instructions by TRY. The token is null for a normal
completion and otherwise a heap object holding the `Unwind` (`Throw`,
`Return(frame, value)`, `Branch(frame, bci, height)`). `UNWIND` pops the
three slots and resumes the token's unwinding. The program can read but
not forge the reason or the token: overwriting the reason no longer
changes control flow.

## Spec and obligations

`unwind` is one recursive function over the frame stack (handler of the
top frame: enter its finally code; target frame of a return or branch:
complete; otherwise pop the frame): 35 lines plus 26 for entering a
finally code, against 75 lines for format 1's UNWIND, without smi
encodings or truncation. The verifier proves the token slot is not
overwritten and `UNWIND` only runs with a token there (the run time checks
the token's body anyway: stuck only if a non-token object is presented).
Proven: TRY, UNWIND, THROW, and the unwinding loop with handler entry.

## Cost

TRY replaces five dispatches: 126 k setups in format 1 vs 64 k in format 2
on the test suite (each format-1 try costs two counted instructions,
LINK and UNLINK). An unwinding through a finally (exception, non-local
return or branch) allocates one token object; a normal completion does
not. 7 bytes saved per try.
