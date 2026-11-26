<!-- Copyright (C) 2026 Toit contributors. -->
# 22. Format 3, steps 1 and 2: short branches and four-word frame records

The format-3 study (format3-study/README.md in the artifacts, candidates S
and A) recommended a package of format changes; this note records the
first two. Bytecodes are bound to the SDK version, so neither keeps
compatibility with older programs or VMs.

## Format number

The image keeps the tag `TBC2` and every tool keeps calling the format
"format 2" until the package is complete. Step 1 makes the format a strict
superset (every format-2 program means the same, the new opcodes are new
numbers) and step 2 does not change the bytecodes at all, so a tag bump
would only reject programs that are still correct. The TRY step of the
package changes the meaning of existing code; the tag becomes `TBC3` there,
once. The verification epoch changes with each step (it digests the spec
crate), so installed untrusted programs need a reinstall after each.

## Step 1: short branches

### Problem

99.7 % of the branch distances of the classic ESP32's system image fit one
byte (2,131 branches), but every branch is three bytes.

### Alternatives

* A signed one-byte distance, four new opcodes: a backward unconditional
  branch is a preemption point (BRANCH_BACK checks the preemption request,
  forward branches do not), so the handler would have to test the sign on
  the hot path, and the spec's "forward offset 0 is stuck" rule would
  become a rule on the sign.
* Short forms of all eight branch opcodes: the backward conditional
  branches are never emitted (0 of 2,131 in the system image; the split
  run loop already keeps them out of IRAM), so their short forms would
  cost three handlers and pay nothing.
* Unsigned forward and backward short forms of the five branches the
  compiler emits (chosen).

### Decision

Five opcodes, each the branch of the same kind with a one-byte distance
(two bytes instead of three):

| Opcode | Number | Long form |
|---|---:|---|
| BRANCH_S | 114 | BRANCH (81) |
| BRANCH_IF_TRUE_S | 115 | BRANCH_IF_TRUE (82) |
| BRANCH_IF_FALSE_S | 116 | BRANCH_IF_FALSE (83) |
| BRANCH_IF_NOT_NULL_S | 117 | BRANCH_IF_NOT_NULL (84) |
| BRANCH_BACK_S | 118 | BRANCH_BACK (85) |

`OPCODE_COUNT2` is 119. The forward forms keep note 9's rule (distance 0
is stuck); BRANCH_BACK_S is a preemption point like BRANCH_BACK. The
numbering keeps `op - BRANCH_S` the branch kind (0 always, 1 if true, 2
if false, 3 if not null) of the forward forms.

**Compiler** (`Emitter::relax_branches`, called once per method after the
last instruction, format 2 only: the format-1 intermediate of `-O2` is
unchanged). The emitter writes every branch in its long form, then:

1. decodes the body into instructions and resolves every distance
   (branches, loop steps, HASH_FIND) to its target instruction;
2. starts with every BRANCH .. BRANCH_IF_NOT_NULL and BRANCH_BACK short
   and lays the code out; a candidate whose distance does not fit a byte
   becomes long; repeat until nothing changes. Distances only grow when an
   instruction grows, so the loop ends (at most one pass per candidate)
   and every branch left short fits in the final layout;
3. rewrites the code with the final distances (the long branches, loop
   steps and HASH_FIND get their u16 recomputed) and a map from old to
   new positions.

The positions recorded during emission move with the code: the absolute
uses and references of non-local branches (the emitter's own lists), and
the source mapper's offsets (call sites, as-checks and expression
positions; `MethodMapper::relocate`), so stack traces and debug
information name the right instruction. A forward branch to a label never
bound (distance 0) stays long; the verifier rejects it as before.
`tests/ctest/branch-relax-test.cc` tests the boundary (distance 254, 255,
256, 257 in both directions and for every condition), a chain where one
branch is short only because the branch it jumps over is, and a loop step
whose distance shrinks.

### Spec and obligations

* `bytecodes.rs`: the five constants, names and lengths (2; the default of
  `opcode_length2`).
* `spec.rs` `step`: BRANCH_S .. BRANCH_IF_NOT_NULL_S is `op_branch(kind,
  bci + b1)`, stuck on `b1 == 0`; BRANCH_BACK_S is `op_branch(0, bci -
  b1)`. Nothing else in the semantics changed.
* `verifier.rs`: `is_branch`, `is_terminator` (BRANCH_S, BRANCH_BACK_S),
  `branch_kind`, the conditional fall-through in `post` (`is_cond_branch`)
  and `terminator_ok` (`is_uncond_branch`) learn the short forms; the
  branch clause of `instr_ok` uses `branch_dist` (one byte for a short
  form, the u16 otherwise) and `branch_target`. The checker (`check.rs`:
  `x_post_misc`, `x_is_terminator`, `x_terminator_ok`, `x_instr_ok`) and
  the certificate inference (`infer.rs`) and encoder (`encode.rs`) follow.
* Soundness: `lemma_step_branch` covers the short forms with the same
  proof (the distance and the length are parameters); the family of
  `sound_instr.rs` includes 114..118. The core's register handlers
  (`step_r`, arms 114..118, hot in both loop configurations) call the same
  `regs::op_branch` with length 2; `lemma_back_branch_s` gives the
  backward bound from the verifier's target map. The checked loop
  (`machine.rs`) and the reference interpreter (`interp/exec2.rs`) decode
  them too. No new trusted item; no theorem statement changed.
* C++: `V2_OPCODE_COUNT`, `V2_OPCODE_LENGTHS` and `V2_BRANCH_S` ..
  `V2_BRANCH_BACK_S` (interpreter_v2.h); the layout check compares the
  numbers with the core's and checks the lengths. `tools/snapshot.toit`
  disassembles them, `tools/asm.toit` assembles them.

### Cost

See verified/core/PROGRESS.md ("Format 3, step 1") for the measurements:
bytecode -3.0 % on the system image, run time unchanged within noise.

## Step 2: four-word frame records

### Problem

A frame record (the core's representation of a spec `Frame` plus the
frame's TRY handler, `verified/core/src/layout.rs`) is five words: method,
return bci, base, handler height (0: no handler) and handler bci. The
handler bci is redundant: a frame has a handler only while it is
suspended in its TRY, and then the frame above it is the try block, whose
return bci is the handler's bci and whose base is the handler's height
(`sound::try_ok`, part of the invariant `wf`). Every call writes the fifth
word and every frame costs it on the task's stack.

### Alternatives

* Three words (method, return bci, base with the handler as a flag bit):
  a block reference is the smi `frame << 16 | slot` and needs `frame <
  2^14`; with stacks below 2^16 words that holds for records of four or
  more words, not three (the study's finding). Three words need another
  block-reference encoding.
* Four words with the handler flag in the callee's record (the try block's
  frame, as in the later TRY step, where TRY becomes a flagged block call):
  while TRY installs its handler and pushes the block's frame, the spec has
  a state with the handler and without the frame above
  (`spec::op_try`'s `s1`), which such a record cannot represent, so the
  machine's TRY could no longer be proved through its intermediate state;
  and the spec's handler belongs to the TRY's frame until the TRY step
  moves it. That step changes the spec and rewrites these paths anyway.
* Four words, the fourth the handler word of today, the handler's bci
  derived from the frame above (chosen).

### Decision

A frame record is four words:

| Word | Contents |
|---|---|
| 0 `FRAME_METHOD` | method index |
| 1 `FRAME_RET` | return bci (into the caller) |
| 2 `FRAME_BASE` | object-stack position of the first argument |
| 3 `FRAME_HANDLER` | 0, or the height of the frame's TRY: the handler flag |

The handler's bci is the `FRAME_RET` of the record above (the try block's
frame), the handler's height equals that record's `FRAME_BASE`; the
fourth word is the flag (nonzero: the frame has a handler) and keeps the
height so that the machine's state between installing the handler and
pushing the try block's frame stays representable. The finally records
keep their five words (`FIN_WORDS` is independent of `FRAME_WORDS`: a call
in finally code moves them by `FRAME_WORDS` with one memmove; the TRY
step removes them). For the TRY step the fourth word becomes the try
block's own flag.

**Block references** stay `frame << 16 | slot`: the records of `n` frames
take `4n` words of a stack shorter than 2^16 words, so `n < 2^14` and the
smi is below 2^30 on every target (`layout.rs`, `BLOCK_SLOT_BITS`).

**The GC and the stack walkers** see only the object stack `[top,
length)`; records hold no references. The C++ that reads records (stack
traces, the profiler, task creation and transfer, stack growth and
shrinking) uses `Stack::V2_FRAME_WORDS` and the word indices, which the
layout check compares with the core's.

### Spec and obligations

The spec is unchanged: `Frame` and `Handler` are the spec's, the record
is the core's representation. In the core, `abs::frames_rel` no longer
relates a word to the handler's bci; `calls::shape_ok` gains
`callees_ok` (a handler of a frame below the top has the try block's
return bci and base as its bci and height: `try_ok`, kept while frames are
popped). Where the core enters finally code it takes the bci from the
try block's record: a return from the try block uses its own return bci,
the unwinding loop the return bci of the frame it popped last. The room
terms (`FRAME_WORDS` per frame), the initial task stack and the C++
constants follow.
