<!-- Copyright (C) 2026 Toit contributors. -->
# 23. Format 3, step 3: TRY as a flagged block call, the pending unwinding in token slots

The format-3 study (format3-study/README.md in the artifacts, candidates C
and B1, "do as one step") recommended making TRY a block call whose frame
record carries a handler flag, and keeping a pending unwinding in the
finally code's own stack slots instead of finally records. This note
records that step. It completes the format-3 package of note 22: the
image tag becomes `TBC3` here.

## Problem

Since note 17 the machine keeps three things for try/finally next to the
frame records:

* the handler stack (`State2::tries`, `Handler { frame, height, bci }`;
  in the core the handler word of the TRY's frame record), with the
  invariant that handlers are sorted by frame, at most one per frame, and
  that the frame above a handler's frame is its try block (`try_ok`,
  `callees_ok`);
* the finally records (`State2::fins`, `Fin { frame, height, resume }`;
  in the core `FIN_WORDS` words each, after the frame records), with
  `fins_ok` (records of live frames, sorted by frame and height, below
  their frame's handler), `cut_fins` on every frame pop, tail call and
  TRY, and `fin_matches` at UNWIND;
* the gate of the register run loop (`fw`, `need`, `bot`): while finally
  records exist, every call moves them up by one frame record and every
  return moves them down (rfins.rs), so the fast call and return paths
  must fail and the slow paths do the moves; the room invariant counts a
  finally record for every frame.

This is the largest family of invariants of the proofs (spec
`try_ok`/`fins_ok`/`fin_ok`/`cut_fins`, core `frames_rel`'s handler part,
`fins_rel`, rfins.rs, the record moves of calls.rs), and the paths it
needs are out of line: a TRY costs about 93 host instructions (`op_try_v`
and `ret_try_v`) against about 40 for a block call, 27.6 TRY and 10.4
non-local returns per RPC.

Note 17 considered keeping the unwinding in the finally code's slots and
rejected it because a branch (frame 14 bits, bci 24 bits, height 16 bits)
does not fit the one smi of the token slot on 32-bit targets, and more
slots "would change the compiler's finally layout". We own the compiler
(bytecodes are bound to the SDK version): the layout can change.

## Alternatives

* The study's sketch: five finally slots (value, a token with kind and
  frame, the target bci, the target height, the reason), all smis.
* Four slots: the value, two token words, the reason (chosen; see the
  encoding below). The kind, frame, height and bci of every unwinding fit
  two 30-bit smis: frame (< 2^14) and height (< 2^16) are a block
  reference's encoding, bci (< 2^28, `prog_rel`) and the kind (2 bits)
  the other word. One word less per finally code than the study's
  sketch, the same number of token words to protect.
* Three slots by merging the reason into a token word: the reason is a
  plain value the compiled code reads (`is-exception` is `reason == -2`),
  a token is unreadable; no.
* Finally records in a separate region (study B2): two-sided room checks,
  the invariant family stays. No.

For the handler:

* A flag bit in the frame record's base word with three-word records: a
  block reference `frame << 16 | slot` then needs frames up to 21,845,
  more than its 14 frame bits (note 22). No.
* The fourth word of the four-word record of note 22 becomes the flag of
  the frame itself (chosen): 1 for a try block called by TRY, 0
  otherwise. The handler's height and bci are that frame's own base and
  return bci, so nothing else is needed.

## Decision

### Bytecode

`TRY` (opcode 97, one byte, no operand) keeps its encoding; its meaning
changes:

* the top slot holds the try block's method id (as before);
* TRY pushes a block reference to that slot and calls the block (arity 1)
  like `LOAD_BLOCK 0; INVOKE_BLOCK 1` would, except that the new frame
  record has its handler word set: the frame is a *try block*;
* when a try block returns (normally, or by a tail call that replaced
  it: the flag stays with the frame), the frame below continues at the
  try block's return bci (the instruction after the TRY) with its object
  stack cut to the try block's base (the TRY's height) and four slots
  pushed: `null`, the two token words of a normal completion, `-1`;
* when an unwinding pops a try block, the frame below continues there the
  same way with the unwinding's slots: the value (the exception, or the
  value of a non-local return, else null), the two token words that
  encode the unwinding, and the reason (-2 for an exception, -1
  otherwise).

`UNWIND` (opcode 99) pops the four slots: a normal token continues with
the next instruction, otherwise the token's unwinding resumes (with the
value slot's value for an exception or a non-local return).

The finally code's slots, bottom first, at the TRY's height `h`:

| Slot | Contents | Verifier kind |
|---|---|---|
| `h` | value: exception, non-local return value, or null | Val |
| `h + 1` | token word A | Token |
| `h + 2` | token word B | Token |
| `h + 3` | reason: -2 exception, -1 otherwise | Val |

The machine words of the tokens (smis, so the GC and every stack walker
treat them as integers):

| Unwinding | A | B |
|---|---|---|
| normal completion | `0` | `0` |
| exception | `0` | `1` |
| non-local return from frame `f` | `f << 16` | `2` |
| non-local branch into frame `f`, bci `b`, height `t` | `f << 16 \| t` | `b << 2 \| 3` |

That is: A is a block reference's encoding (`abs::block_word`) of the
target frame and height, B is `bci * 4 + kind`. Frames are below 2^14 and
heights below 2^16 (stacks are shorter than 2^16 words), absolute bcis
below 2^28 (`prog_rel`), so both are non-negative smis below 2^30 on
32-bit targets.

The image tag becomes `TBC3` (format 3). `Program::is_format2()` (the
"verified-core format" predicate, kept under its name) is true for `TBC3`
only. An image tagged `TBC1`/`TBC2` or any other `TBC` digit is a stale
verified-core image: it is refused where a program is started, with the
existing errors (`FORMAT_2_REQUIRED` for containers, the "format-2
required" message of `toit.run`/`toit.compile`), and is never run by the
format-1 C++ interpreter. The compiler's selector stays
`-Xbytecode_format=2` / `TOIT_BYTECODE_FORMAT=2` ("the verified-core
format", whose current version is 3): renaming it would touch every build
configuration for no gain; the tools print "format 3".

### Spec

`State2` loses `tries` and `fins`; `Frame` gains `handler: bool` (the
frame is a try block). `Handler`, `Fin` and `Resume` are removed;
`Body::Stack2` keeps the object stack, the frames and the bci.

Tokens are values with provenance (as block references are):
`Value::Token(second, pending, frame, height)`, where `second` says
which of the two words it is, `pending` is the unwinding without its
value (`Pending::{Normal, Throw, Return(f), Branch(f, bci, h)}`), and
`frame` and `height` are the frame running the finally code and the
height of its value slot. Only entering a finally code creates tokens.

* `op_try`: the top slot's block method (else INVALID_PROGRAM), arity 1
  (else CODE_INVOCATION_FAILED), then `call` with the block reference
  pushed, and the new frame flagged. Both raises happen in the TRY's own
  state, without a handler (before, the handler was installed first, so
  the exception entered the TRY's own finally code; accepted programs
  never raise there).
* `return_from(s, v)`: pops the top frame; a try block enters the finally
  code of the frame below (`enter_finally(pop_frame(s), base, ret,
  None)`), anything else pushes the result and continues at the return
  bci. The old "stuck if the top frame has a handler" case is gone (a
  handler is a property of the running frame now, not of the frame below
  it).
* `unwind(s, u)`: a non-local return or branch whose target is the top
  frame completes; otherwise the top frame is popped, and if it was a try
  block the finally code of the frame below starts with `u`
  (`enter_finally(pop_frame(s), base, ret, Some(u))`), else unwinding
  continues; an exception past the bottom frame ends the task. Before,
  the check "the top frame has a handler" came first; a frame with a
  handler was always reached by popping its try block, so the order of
  events is the same.
* `enter_finally(s, h, bci, u)`: cuts the object stack to `h`, continues
  at `bci` and pushes the value, `Token(false, pending, top, h)`,
  `Token(true, pending, top, h)` and the reason.
* `op_unwind`: the slots at 2 and 1 must be `Token(false, d, top, h)` and
  `Token(true, d, top, h)` for the same unwinding `d`, the frame running
  the UNWIND and `h + 4 ==` the stack's length; anything else is
  `Stuck(NotUnwind)`. Then the four slots go and `d` resumes (`Normal`:
  the next instruction).
* `replace_frame` (tail calls) keeps the frame's flag, no longer cuts
  records, and is no longer stuck on a handler. `pop_frame` no longer
  cuts records.

The misuse a program could attempt is therefore stuck in the spec, and
so excluded by the soundness theorem for accepted programs:

* forging a token (any other value in a token slot, a token of another
  unwinding, of another frame or at another height, the two words of
  different unwindings);
* resuming an unwinding twice (a copy of a token is at another height:
  a token's own height is part of it);
* resuming an unwinding as a normal completion or the other way round
  (the kind is part of the token).

A program can still leave a finally code without resuming its
unwinding, by the Toit control flow that does it on purpose: `break`,
`continue` or `return` out of finally code, or an exception thrown in it,
pop the slots and drop the unwinding (the language's semantics; format 1
and note 17 behave the same). No other way exists: the code after the
UNWIND is reached from the finally code only through UNWIND (a branch
from inside the finally code to it would need the token slots in the
target's map, which only the finally code has), and UNWIND resumes a
pending unwinding.

### Verifier

The rules change only in the number of slots:

* TRY's successor kinds are the TRY's kinds plus `[Val, Token, Token,
  Val]` (was `[Val, Token, Val]`);
* UNWIND requires `Token` at 1 and 2 and a value at 3 and pops four;
* a frame suspended in a TRY (its frame above is a try block) has its
  TRY's map plus the four slots (`frame_shape_ok`).

Everything that protects token slots stays: LOAD_LOCAL, POP_LOAD_LOCAL,
LOAD_OUTER and the loop steps never copy a token; nothing stores into a
token slot or stores a token (`writable`); below a token only plain
value slots are overwritten, with plain values, so a pending branch
into the frame finds the kinds it was checked against. The certificate
format is unchanged (the kinds are the same).

The invariant (`sound.rs`):

* gone: `try_frame` over `tries`, `try_ok`, `fin_lt`, `fins_ok`, `fin_ok`;
* `try_frame(s, g)` is "frame `g + 1` is a try block"; the bottom frame
  is never a try block (`wf_task`);
* a token conforms to `Kind::Token` in slot `j` of frame `fi`
  (`conf`): it is `Token(second, d, fi, h)` with `h` its value slot
  (`fbase + j - 1`, or `- 2` for the second word), `pending_ok(d)` (as
  before over `Resume`: returns and branches target frames at or below
  `fi`, a branch a mapped offset whose map is a prefix of the target
  frame's kinds, below the token in its own frame), and the second word's
  slot below holds the first word of the same unwinding.

### Core

* A frame record stays four words; `FRAME_HANDLER` is 1 for a try block,
  0 otherwise. `frames_rel` relates it to `Frame::handler` directly (no
  handler stack, no `callees_ok`).
* No finally records: `rtop`, `FIN_WORDS` and the `FIN_*` words, the
  gate (`fw`, `need`, `bot`), rfins.rs, `fin_cut`, `cut_records`,
  `pop_records`, `fins_rel` and the record moves of calls and returns
  are gone. The Stack object's record word holds the frame top only.
* TRY is a block call with the flag (the room check of a call), RETURN
  tests the returning frame's handler word (one load, as it tested the
  caller's before) and enters the finally code of a normal completion out
  of line; UNWIND reads token B and pops four slots on a normal token
  (one load, one compare), otherwise decodes the unwinding and runs the
  unwinding loop; the unwinding loop tests the handler word of each frame
  it pops.
* Room: every frame's room (its base, arity and the program's maximal
  height above the records, plus the reserve, `room_ok`) covers its
  finally slots, which the verifier counts in the TRY's successor map,
  so entering a finally code needs no room check and no rescan
  (`ensure_room_all` after an unwinding is gone); the room no longer
  counts finally records.
* `Machine::reload_cold` (trusted) checks `ftop % FRAME_WORDS == 0`
  and `ftop <= top`; no record region.

### Compiler

`ByteGen::visit_TryFinally` emits the try block, `TRY`, the finally code
(the handler parameters map to slots `h + 3`, the reason, and `h`, the
value), `UNWIND`, `POP 1` (the try block's method id). `Emitter::try_finally`
remembers four slots, `Emitter::unwind` pops four. `catch`, the monitor
pattern (`locked_` runs the method body as a block inside a try/finally;
monitor.cc turns a `return` of the body into the block's exit so that it
does not unwind through the finally code), `critical-do`, task
cancellation (CANCELED-ERROR thrown at the checkpoints and run through
every finally code) and the RPC paths are library code over try/finally
and non-local returns: they compile as before with four slots instead of
three. A non-local return or branch out of a try block (a `return` in a
try body, `break` out of a block loop) is NON_LOCAL_RETURN /
NON_LOCAL_BRANCH as before; it enters the finally code when it pops the
try block. `return` or `break` inside finally code pops the four slots
(the branch's height adjustment or the frame's pop) and so drops the
pending unwinding, as Toit specifies.

### What happens at the machine's edges

* **Stack growth and shrinking** copy the frame records and the object
  stack; the token words are smis in object-stack slots. Positions are
  counted from the bottom, so a token's frame and height stay valid.
* **GC stack scanning** sees only `[top, length)`; token words are smis
  (no references). A collection during finally code (a call in it)
  keeps them.
* **Stack traces and the profiler** walk the frame records; the handler
  word is not read by them.
* **Task switch and preemption** at any point (calls, backward branches,
  primitives, yields): the pending unwinding is part of the suspended
  stack (`Body::Stack2`), nothing else to save. A new task's records
  have no flag.
* **Out of memory, stack overflow during unwinding**: unwinding
  allocates nothing and entering a finally code needs no room, so
  neither can happen while unwinding. A call inside finally code can
  overflow the stack or run out of memory like any call: the resulting
  exception unwinds from there, popping the finally code's frame with its
  token slots (the earlier unwinding is dropped, as when the finally code
  throws).

## Deviations from the study

* Four slots instead of five (the token words pack frame, height, bci
  and kind as above).
* The spec's tokens are values with provenance carrying their own frame
  and height, so that forging, copying and mixing tokens are stuck states
  of the spec (the study sketched `pending_ok` on decoded smis: the spec
  would then have given a forged smi pair a meaning).
* The TRY opcode stays (one byte, no operand) instead of becoming an
  INVOKE_BLOCK variant: the block reference to the top slot is implicit.
* A raise of TRY (bad operand) no longer enters TRY's own finally code
  (the study's "reordered").

## Spec and obligations

Changed definitions: `types.rs` (`Frame`, `Value::Token`, `Pending`,
`Body::Stack2`; `Handler`, `Fin`, `Resume` gone), `v2/types.rs`
(`State2`), `spec.rs` (`call` flags nothing, `op_try`, `return_from`,
`enter_finally`, `unwind`, `pop_frame`, `replace_frame`, `op_unwind`;
`has_handler`, `cut_fins`, `fins_popped`, `resume_of`, `unwind_of`,
`fin_matches` gone), `verifier.rs` (TRY, UNWIND), `sound.rs` (as
above), `prim.rs` (task switching keeps no handlers or records).
The theorem statements (`theorem_soundness`, `theorem_initial`, the
core's refinement and process theorems) are unchanged in text; they
refer to the new definitions.

## Cost

See verified/core/PROGRESS.md ("Format 3, step 3") for the
measurements.
