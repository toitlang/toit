# The revised bytecode format (format 2, now version 3)

Phase 2 of `07-verified-sandbox-plan.md`. Format 2 is the bytecode format
of the verified core. It is specified in `src/v2` (Verus), produced by the
compiler (`src/compiler/bytecode_format.h`; the default on builds with the
verified core since docs/format2-migration.md, `-Xbytecode_format=1` for
format 1), decoded by `tools/snapshot.toit`, and run by the reference
interpreter (`src/interp/exec2.rs`, with 72 opcodes running through the
verified `src/v2/exec.rs`). The C++ interpreter does not run it.

## Decisions

One note per decision, each with the alternative considered, the effect
on the spec and on the soundness obligations, and the cost.

| # | Note | Decision |
|---|---|---|
| 1 | [method-table](01-method-table.md) | Method ids are indices into a method table decoded from method headers that carry the body length, the receiver range and the accessor's field. |
| 2 | [frame-stack](02-frame-stack.md) | Return addresses live on a separate frame stack; the object stack holds only values; every local access is bounded by the frame. |
| 3 | [block-references](03-block-references.md) | A block reference is `(frame, slot)`, no salt; non-local return and branch name their frame through it. |
| 4 | [try](04-try.md) | One `TRY` instruction with a handler stack; the finally code gets an unforgeable unwinding token; `UNWIND` resumes it (the token became a finally record's index in note 17, and the pending unwinding the finally code's token slots in note 23). |
| 5 | [raised-failures](05-raised-failures.md) | Lookup, as-check, code-invocation, invalid-program and primitive-lookup failures are exceptions raised by the machine. |
| 6 | [tail-calls](06-tail-calls.md) | Tail calls replace the top frame; no height/arity operands. |
| 7 | [field-access](07-field-access.md) | Field access is checked; `LOAD_FIELD_THIS`/`STORE_FIELD_THIS` are unchecked, backed by the method's declared receiver range, a receiver check at static calls and a dispatch-table check. |
| 8 | [terminators](08-terminators.md) | Every method body ends in a terminator; execution never leaves a method's body. |
| 9 | [branches](09-branches.md) | Forward branches with offset 0 are illegal; branch targets stay in the method; `BRANCH_BACK` loses its second operand. |
| 10 | [interface-stubs](10-interface-stubs.md) | Interface-check stubs get a real (throwing) body. |
| 11 | [intrinsics](11-intrinsics.md) | The four intrinsics are removed (added candidate). |
| 12 | [heap-method-ids](12-heap-method-ids.md) | Method ids read from the heap or a block slot are checked at run time (index, kind, captures). |
| 13 | [encoding](13-encoding.md) | Smaller operand changes, opcode numbering, no silent wrapping. |
| 14 | [rejected](14-rejected.md) | Candidates rejected or deferred: block masks in headers, unique frame ids, runtime dispatch bounds, shipped stack maps. |
| 15 | [header](15-header.md) | The method header is two bytes plus LEB128 fields (5.2 bytes on average instead of 16); format 2 is 4.2 % smaller than format 1. |
| 17 | [finally-records](17-finally-records.md) | A pending unwinding is a record next to the handlers (no heap token, no allocation); the token is its smi index; UNWIND checks it belongs to the frame. Replaces note 4's heap token; replaced by note 23 (tokens in slots). |
| 16 | [hash-find](16-hash-find.md) | Recommendation: bring `HASH_FIND` back in Phase 4 as a non-re-entrant verified built-in; decide a `REPEAT` instruction on the same benchmark; keep HASH_DO and ARRAY_DO out. |
| 18 | [shipped-certificate](18-shipped-certificate.md) | The toolchain ships the verifier's certificate (bundle member, trailing image block); the device reads its tables in place, decodes one method's maps at a time and only checks (`cert::verify_shipped`, proven); the installer may drop it. Decides note 14's "shipped stack maps". |
| 19 | [builtins-proposal](19-builtins-proposal.md) | **Proposal, not decided** (branch proposal/builtins): LOOP_REPEAT, LOOP_ARRAY and HASH_FIND as bounded, non-reentrant steps that never write the heap, whose loops stay in the bytecode; specified, verified, proven (no new trusted item) and measured per built-in for the owner's decision. |
| 20 | [unchecked-twins](20-unchecked-twins.md) | **Experiment, not decided** (branch experiment/trusted-fast): the unchecked twins of the field accesses (opcodes 104..113) for trusted programs, replacing the unchecked mode flag; untrusted programs keep the checked opcodes and cannot use the twins. |
| 22 | [format3-branches-frames](22-format3-branches-frames.md) | Format 3, steps 1 and 2: two-byte short forms of the five branches the compiler emits (BRANCH_S .. BRANCH_IF_NOT_NULL_S, BRANCH_BACK_S; the compiler relaxes branches to a fixpoint), and four-word frame records (the handler bci is the try block's return bci). The image keeps the tag TBC2 until the package is complete. |
| 23 | [format3-try](23-format3-try.md) | Format 3, step 3: TRY is a block call whose frame carries the handler flag; the pending unwinding lives in the finally code's two token slots (four slots: value, two token words, reason); no handler stack, no finally records. The image tag becomes TBC3. |

## Verifier versus run time

The structural verifier (`src/v2/verifier.rs`, soundness proven in
Phase 3, see `SOUNDNESS.md`) proves:

* stack discipline: heights at every instruction, all slot accesses
  inside the current frame, no frame's slots below its base;
* block references: only created from block slots, never stored in the
  heap or a global, never returned, never left dangling (a block slot is
  not popped or overwritten while referenced), non-local returns and
  branches only to outer frames, at instruction boundaries of the outer
  method with the right height;
* try/finally: tokens only in finally slots, `UNWIND` only on a token;
* branch targets, terminators, operand ranges (literals, globals,
  classes, typecheck tables, method ids of `LOAD_METHOD`);
* `this` field accesses: the receiver range has the field, parameter 0 is
  never overwritten; dispatch-table entries respect receiver ranges;
* table shapes: dispatch entries are methods, selectors fit the table,
  methods sharing a selector agree on arity and block parameters.

The machine checks at run time (and raises an exception, never stuck):
method ids from lambdas, lazy initializers and block slots (index, kind,
arity, captures), field receivers and indices of the checked field
instructions, writes to read-only (program-heap) objects, dynamic global
indices, receiver classes of static calls with a declared range, the
selectors of the operators (a tree-shaken operator is a lookup failure),
and every fast path that reads Toit-level collection fields (a corrupted
collection falls back to the virtual call).

## Measured effect

On the 268 tests of the repository's suite that run on the reference
interpreter in both formats (`toit run verified/tools/measure.toit --
target/suite-both.json`):

| | format 1 | format 2 | |
|---|---|---|---|
| executed instructions | 72.8 M | 83.0 M | +13.9 % (intrinsics, notes 11 and 16; 259.9 M -> 317.4 M, +22.1 %, over the 272 tests of the later suite) |
| method bodies (bytes) | 6.96 M | 6.24 M | -10.3 % |
| method headers (bytes) | 0.88 M | 3.37 M | 4 -> 16 bytes; 1.12 M with the header of note 15 |
| checked field loads / unchecked (`this`) | 2.14 M / 0 | 0.19 M / 2.40 M | |
| checked field stores / unchecked (`this`) | 0.53 M / 0 | 0.06 M / 0.51 M | |
| try setups (LINK+UNLINK / TRY) | 126 k | 64 k | |
| steps through verified code | 65 % | 85 % | 47 -> 72 proven opcodes |

Spec size (non-comment lines): format 1 `spec_step.rs` 1242 + shared
vocabulary; format 2 `v2/spec.rs` 1074 + `v2/prim.rs` 128 + `v2/types.rs`
97, reusing the heap vocabulary of format 1. The intrinsics alone were 428
lines of format 1. Proofs: `exec_step.rs` (format 1, 47 opcodes) 986
lines, `v2/exec.rs` (72 opcodes, including the unwinding loop) 1615 lines;
both verify with zero admits (340 items, about 5 s).
