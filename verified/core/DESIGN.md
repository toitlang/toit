# The verified core: design

The Rust interpreter core for bytecode format 2 (verified/spec/format),
running whole processes inside the C++ Toit VM on x86-64 (Phase 4 of
07-verified-sandbox-plan.md). Untrusted containers run on it; trusted
containers and the system process stay on format 1 and the C++
interpreter. Status and next steps: PROGRESS.md. Proof status:
OBLIGATIONS.md. Trusted base: TRUSTED.md and verified/TRUSTED.toml.

## 1. Format dispatch

- A program is format 2 iff its bytecodes start with the tag `TBC2`
  (`Program::is_format2`). The compiler emits format 2 with
  `-Xbytecode_format=2`, with `TOIT_BYTECODE_FORMAT=2` in the environment
  (test runs), and always for `toit.run --untrusted` (source programs).
- `V2MethodTable::compute` (src/interpreter_v2.cc) decodes the method
  headers (note 15) into a table of `V2Method`; it checks only the header
  encoding and that every body lies inside the bytecodes
  (`entry <= end <= bytecodes.len()`, TRUSTED.md V3). Malformed headers:
  `INVALID_SNAPSHOT`.
- Untrusted launches decode the table once, run the verified structural
  verifier on it (verified/vmverify: `check::verify` and the heap check,
  untrusted rules, on the abstract program built from the very tables
  this section's `toit_v2_program` describes) and hand that table to the
  process group; a rejected program never runs (`VERIFICATION_FAILED`,
  the reason on stderr). Trusted format-2 programs are verified only with
  `-Xverify`/`TOIT_VERIFY` (trusted rules); unverified, they rely on the
  core's run-time checks of every stuck state.
- `Interpreter::run` and `prepare_process` hand format-2 processes to
  `run_v2` / `prepare_process_v2`; the scheduler is unchanged (it calls
  `Interpreter::run` as before). `load_stack`/`store_stack` are no-ops for
  format 2: the core keeps the stack object up to date itself.
- Untrusted containers must be format 2: programs-registry spawn and
  snapshot launch refuse a format-1 program under the untrusted policy
  with `FORMAT_2_REQUIRED`. `-Xuntrusted_format1` or
  `TOIT_UNTRUSTED_FORMAT1=1` allows format 1 again (then it runs on the
  C++ interpreter). **Default: format 2 required.**
- With the CMake option `TOIT_VERIFIED_CORE` off (default off for
  embedded and cross builds, or without cargo) the VM builds without the
  core and refuses to run format-2 programs.

## 2. Run-loop contract (`toit_v2_run`)

`Interpreter::run_v2` fills a `toit_v2_context` (program tables, globals,
heap range, remembered-set bias, `&watermark_`, flags) and calls
`toit_v2_run`, which owns the run loop of the process until it returns,
with the contract of `Interpreter::run`:

- On entry the current task's Stack object holds the task state (object
  stack, frame and finally records, top, record top, bci and the number
  of finally records); on return it holds the
  state to continue from. The core never holds the state elsewhere across
  a return or a GC point.
- It returns `PREEMPTED` (watermark set: checked after a call has set up
  the callee's frame, as format 1 does at the callee's entry, and at
  backward branches), `YIELDED` (HALT 0, with 91 pushed), `TERMINATED`
  (HALT 1 with its value; an uncaught exception or a returning bottom
  frame with 1; a stuck state with 1 and a report on stderr),
  `DEEP_SLEEP` (HALT 2) or `RESET` (HALT 3). `run_v2` then clears the
  watermark as `run` does and sets `preemption_method_header_bcp_` to the
  header of the top frame's method for the profiler.
- Task switches happen inside the `task_transfer` primitive
  (`Interpreter::v2_task_transfer`); the core continues with whatever task
  is current afterwards. A new task's first transfer builds its entry
  frames (`v2_start_task`).

Inside, `machine::run` runs one of two loops (section 9): for a program
the launch accepted (`toit_v2_context.accepted`: untrusted programs, or
any program with -Xverify / TOIT_VERIFY=1), the verified loop
`step::run_loop`, whose handlers are proven to refine `spec::step` and
rely on the verifier instead of run-time checks (no instruction-in-method
check, no slot, index, target or arity checks); otherwise
`machine::run_checked`, where every stuck state of the spec is a run-time
check that ends the process (`Ctl::Stuck`), as before.

Register allocation: hot handlers are `#[inline(always)]`; every path that
calls an out-of-line function goes through `cold!`, which moves the
`Machine` into the callee by value and back, so the machine's address
never escapes and LLVM can keep fields in registers. The frame cache and
the program/globals views are deliberately kept in memory (`black_box` of
their addresses in `run`): promoting all fifteen fields made LLVM shuffle
them through vector registers at the loop head, which cost more than the
loads.

## 3. Stack layout

The task's existing `Stack` heap object holds both stacks, so stack
growth, GC root scanning and C++ primitives work as before:

```
array index:  0 ........... ftop ........ rtop        top ............. len-1
              [ frame records ][ finally rec. ][  free  ][ object stack, top first ]
```

- Object stack: `array[top..len)`, growing down; object-stack position
  `i` (counted from the bottom) is `array[len - 1 - i]`, so positions
  survive growth and shrinking. Holds only smis and heap references; the
  GC visits exactly `[top, len)` (`Stack::roots_do`).
- Frame records: `array[0..ftop)`, growing up, 4 words each (method
  index, return bci, base = object-stack position of the first argument,
  handler = 0 or `height | bci << 32` of the frame's TRY), frame `fi` at
  `4 * fi` (block references and C++ rely on that).
- Finally records (format note 17, `State2.fins`): `array[ftop..rtop)`,
  right after the frame records, 4 words each: the frame running the
  finally code, the height of its three slots, the resumed unwinding
  (`kind + 4 * frame`: kind 0 throw, 1 return, 2 branch) and the branch
  target (`bci | height << 32`, else 0). The token slot of the finally code
  holds the smi index of its record. Entering finally code with an
  unwinding writes a record at `rtop` (the handler word is cleared as for a
  normal completion); UNWIND checks record `k` (`fin_matches`) and sets
  `rtop` to it; TRY drops the frame's stale records (`cut_fins`). A call
  moves the records up by one frame record (`memmove`, only when there are
  records: during an unwinding's finally code); a return, an unwinding
  that pops a frame and a tail call drop the popped frame's records (they
  are last, `fins_popped`) and a return or pop moves the rest down by one
  frame record. Records are 4 words although three would do (frame and
  height fit one word): the same size as a frame record keeps a call's
  move and every index computation a shift, and the records are rare.
- Records hold no object references (the value of a pending exception or
  non-local return is the finally code's first slot), so the GC never
  looks at them. The Stack header's try-top word holds the record top
  `rtop`, the pending-stack-check word `bci | fins << 32` (`fins`: the
  number of finally records, `ftop = rtop - 4 * fins`). Holding the record
  top (not the frame top) in the header lets every C++ path that copies or
  shrinks a stack keep `[0, try-top)` without knowing about finally
  records; C++ reads the frame top through `Stack::v2_frame_top()`.
  Alternatives: a separate header word (changes format 1's Stack layout
  and every stack's size), the count in the high half of the try-top word
  (same packing, but `try_top()` is shared with format 1's code), records
  in the frame records themselves (one per frame: unsound for try/finally
  inside finally code, note 17).
- Room: before every call the core requires
  `FRAME_WORDS + global_max_height + STACK_RESERVE` free words between the
  records and the object stack and otherwise grows the stack
  (`toit_v2_grow_stack`: a new, larger Stack, records copied to the bottom
  and the object stack to the top). Growth past `Stack::max_length()`
  throws `STACK_OVERFLOW`. Entering finally code with an unwinding needs
  the record and three slots; the popped try-block frame freed its frame
  record and argument, and the reserve covers the rest (the run-time check
  stops with `LIMIT` otherwise).
- Shrinking (GC, `Stack::roots_do`) moves the object stack down and keeps
  the records and the reserve.
- Task switches: a suspended task's records stay in its Stack object (the
  core saves `rtop` and the count before the `task_transfer` primitive and
  reloads them from the new current task); a new task starts with none.
- Proofs: `Machine::refines` relates `State2.fins` to the records
  (`abs::fins_rel`, `rtop == ftop + 4 * fins.len()`). The record handling
  of calls, returns (`calls.rs`: `push_call`, `pop_records`,
  `cut_records`) and of THROW, TRY, UNWIND, NON_LOCAL_RETURN and
  NON_LOCAL_BRANCH (`unwind.rs`, one inlined unwinding loop for all of
  them) is verified; machine.rs keeps checked copies for the unverified
  paths (raising, programs not accepted at launch), which must stay in
  step with the verified ones.
- Block references are smis `frame << 20 | slot` (slot = object-stack
  position); `Stack::max_length() < 2^20` is checked by the layout check.

## 4. FFI contract

Every C++ function the core calls (src/interpreter_v2.h), with the
precondition the core discharges. "MAY GC" functions take the stack view
by `&mut` and replace it; before each the core stores top, frame top and
bci with the number of finally records into the Stack object
(`Machine::save`), after each it re-derives all cached state from the
current task's stack (`Machine::reload`, which also re-checks top, record
top, the finally-record count and length).

| Function | MAY GC | Precondition discharged by the core | Result |
|---|---|---|---|
| `toit_v2_current_stack(process)` | no | process is the running process | the current task's Stack |
| `toit_v2_allocate_instance(process, class_id)` | yes | `class_id < class_bits.len()`, its tag is instance, state saved | instance with null fields, or 0 |
| `toit_v2_allocate_double(process, bits)` | yes | state saved | double, or 0 |
| `toit_v2_allocate_array(process, length, filler)` | yes | filler is a smi, null or a program-heap object (survives GC); state saved | array, or 0 (also for length > max) |
| `toit_v2_allocate_exception(process, value, kind, words, count)` | yes | value is a program-heap object (failure literal or root); `count <= 4`; the words are read only before the first GC point; state saved (the trace is encoded from the saved stack) | `Exception_` with trace, or 0 |
| `toit_v2_grow_stack(process, needed)` | yes | state saved (record top and finally-record count included) | OK, STACK_OVERFLOW or OUT_OF_MEMORY; on OK the task has a new stack with the frame and finally records copied and `needed` free words above them |
| `toit_v2_lookup_primitive(process, module, index, &entry, &arity)` | no | none (bounds-checked in the policy) | FOUND or MISSING |
| `toit_v2_call_primitive(process, entry, arity, first, &result)` | yes, may switch task | `entry` came from lookup; `arity` equals the primitive's arity and the method's; the arguments are object-stack positions `first..first+arity` of the current frame; state saved | SUCCESS (result), FAILURE (error value, pushed) or THROW (raise it); after a task switch the new task's Stack holds its records (none for a new task) |
| `toit_v2_report(process, kind, bci, detail)` | no | none | message on stderr |

The C++ primitive path is unverified and outside the security boundary
(TRUSTED.md section 2). Ported primitives: none yet. For untrusted
programs the policy resolves only the allowed set of
docs/sandbox-policy.md; all of them currently run as C++ (open work: port
them to Rust with `prim_heap_ok`, OBLIGATIONS.md S1). Timer and event glue
stays C++ (it is reached through primitives and the scheduler).

GC-safety discipline: OBLIGATIONS.md, G.

## 5. Raised failures and traces

The machine raises the five failures of note 5 itself. The value is the
literal of the spec; in addition the core passes the message words the
format-1 failure entry point would have encoded (LOOKUP_FAILED:
selector offset, class id, receiver; AS_CHECK_FAILED: value and the
absolute bci after the check, where the compiler records the class name;
CODE_INVOCATION_FAILED: is-block, expected, provided, target entry;
INVALID_PROGRAM: bci; PRIMITIVE_LOOKUP_FAILED: module and index as text).
C++ encodes them into the trace without allocating
(`ProgramOrientedEncoder::encode_error` with an element array), so failure
output matches format 1.

## 6. Measurements

See section 8 for the tables. Benchmarks: /home/flo/work/benchmarks/toit
(richards, deltablue, pystone), compiled with toit.compile (format 1) and
`TOIT_BYTECODE_FORMAT=2` (format 2), run with build/host toit.run on the
same machine (32 cores, shared with other jobs: wall times are the minimum
of 5 runs). They use only allowed primitives except `process_stats`
(system module, denied for untrusted programs), so they run trusted; the
core executes them the same way it executes untrusted programs.
Scripts: build/bench/ir.sh (instruction counts), build/bench/hot.sh
(per-instruction profile of the run loop).

## 7. Testing

- tests/sandbox: compiled in format 2 (CMake sets
  `TOIT_BYTECODE_FORMAT=2`): the untrusted containers and the drivers run
  on the core. Two CLI tests cover the format-1 refusal and the switch.
  verify-reject-test pins format 1 (it tests the format-1 verifier's
  options and fuzzer).
- verified/core/tests/untrusted_suite.py: every program the reference
  interpreter can run (run_suite.py status `pass` or `steplimit`) runs
  untrusted in format 2 and trusted in format 1; stdout and exit code
  must match.
- verified/core/fuzz/fuzz.py: mutates format-2 snapshots, launches each
  untrusted on an ASan build; the VM's launch-time verifier is the
  filter (`--filter=spec` uses `toit_spec_verify` on a dump instead).
- The whole suite with `TOIT_BYTECODE_FORMAT=2` (not required any more,
  still useful): see PROGRESS.md for the current failures and why.
- `TOIT_V2_VALIDATE=1` (debugging aid) checks every object-stack slot of
  every live task before and after each GC and at run entry and exit.

## 8. Measurement tables

Measured 2026-11-10 at commit 8d533501 (+ this table), release build,
x86-64 (32 cores shared with other jobs). Wall: time per iteration as the
benchmark prints it, minimum of 5 runs. Ir: callgrind instruction count of
the whole run (startup about 6 M).

| Benchmark | f1 wall ms | f2 wall ms | ratio | f1 Ir | f2 Ir | ratio |
|---|---|---|---|---|---|---|
| richards | 14.22 | 30.25 | 2.13 | 1,031 M | 3,953 M | 3.83 |
| deltablue | 8.17 | 21.21 | 2.60 | 655 M | 2,705 M | 4.13 |
| pystone | 9.55 | 28.54 | 2.99 | 770 M | 2,660 M | 3.46 |

The plan allows 20 percent; the core is 2.1-3.0x slower in wall time and
executes 3.5-4.1x the instructions. History of the run loop (richards,
f2 wall ms from single runs under varying load, so only indicative):
70.5 (first version, state in memory, 24-byte `Ctl` returned through
memory, out-of-line operator handlers) -> 31.3 (inlined fast paths,
16-byte `Ctl`, one-comparison prologue, `cold!` trampolines) -> about 25
(frame cache kept in memory). Loop microbenchmark (`for` loop with an
addition, 15 bytecodes per iteration): format 1 141 instructions per
iteration, format 2 first version 830, now about 640.

Where the time goes (richards: 71.6 M format-2 instructions executed, 55
machine instructions each; pystone: 49.3 M, 54 each; the C++ interpreter
needs about 14 per format-1 instruction):

- Dispatch and loop overhead, about 15-20 per instruction: the prologue
  (`bci < mfast`), the jump table, the `Ctl` result test and the loop
  back edge; the C++ interpreter's threaded dispatch is 5-7.
- Run-time checks the spec makes stuck states, 10-15 per instruction:
  `has_slot` on every stack access (`n < lim - top`, both loaded),
  `push` room checks, field checks (`field_ok`: tag, class id range,
  class_bits lookup, field count) on every field access including
  LOAD_FIELD_THIS (whose receiver the loader already checked), method
  range checks on branches.
- Program tables read through two indirections (`env.p` then the table
  pointer) because `env` escapes into the cold paths: about 5 per
  instruction (`Table::at` is 15 percent of all instructions).
- Format 2 has no intrinsics (note 11): `SmallInteger.repeat` and similar
  loops are ordinary bytecode, so format 2 executes more instructions
  than format 1 for the same program.

Next steps for the performance pass, in expected order of effect: keep
`top`/`bci`/the code pointer in run-loop locals passed to the handlers;
drop checks the verifier makes redundant once untrusted launches run the
verified verifier (receiver of LOAD_FIELD_THIS, branch target range, room
checks that `global_max_height` already covers); cache table pointers in
the machine; tail-call threading if the toolchain supports it
(`become`); the REPEAT instruction of note 16.

## 9. Proofs: abstraction, refinement, the end-to-end theorem

The core is proven against the format-2 specification of verified/spec
(`v2/spec.rs::step`) and the soundness theorem of its verifier
(`v2/theorem.rs`, SOUNDNESS.md). verified/check.sh verifies the spec crate
first and exports its Verus metadata; the core crate depends on it
(Cargo) and imports it, so the core's proofs use the spec's definitions
and lemmas directly.

Abstraction (`src/abs.rs`, `Machine::refines` in `src/exec.rs`). The
machine carries a ghost `State2` (`Machine::g`); `refines` relates it to
memory in the direction abstract to concrete, which is a function:
`enc(addr, v)` is the word of value `v` (smis `v << 1`, objects their
address in the heap model, block references the smi `f << 20 | slot`),
the object-stack words are `enc` of `g.stack`, the frame records
`mem[4*fi..]` hold `g.frames` and the handler words `g.tries`
(`frames_rel`), the globals are `enc` of `g.globals`, the heap model is
`g.heap`, and the cached top-frame fields agree. Reading a state off the
words is not a function (a block reference and a smi can be the same
word; addresses change at every GC), which is why the design keeps the
ghost state instead of a decoding `abs(m)`: `abs(m)` is `m.g@`, constrained
by `m.refines(p)`. The program tables are related to the abstract program
`p.ap` by `prog_rel` (the loader's contract). The trusted views
(TRUSTED.md section 1) state their contracts in these terms: the heap
view's accessors read and write the model (`Heap::objs`, `addrs`,
`class_bits`); `heap_model_ok` is the formal form of "heap integrity".

Refinement. Every verified handler takes `handler_pre` (the machine
refines `g`, `wf(g)`, the program is accepted, `step_ok(g)` from the
spec's `lemma_step`) and the fact that `step(p, g)` is the spec function
of its opcode, and ensures `step_post`: on `Next` the new machine refines
exactly the next state of `step` (or a completion, or the same state when
the instruction did not run, e.g. stack growth before a call); exits
preserve it for preemption and yield; the only stuck result is the
resource stop `LIMIT`. Every run-time check that `step` being not stuck
implies is gone. Paths not proven yet (raising an exception, doubles and
other slow paths, and the opcodes not verified) hand the whole
instruction, before changing anything, to `step_unverified`, whose
contract is assumed (allowlisted; OBLIGATIONS.md).

Run loop (`src/step.rs`). The loop invariant is `Machine::inv` (refines,
accepted, `wf`) plus `reaches(start, g)`: the state is reached from the
run's start by `advances` steps (spec steps, completions, the same state,
or a resource throw). `wf` is re-established after every step from the
spec's `step_ok` (preservation is the verifier's soundness proof).

End-to-end theorem (`src/theorem.rs`). The verified run loop has
`requires inv` and `ensures run_post` (never a stuck state of the spec,
never a fatal path; preempted/yielded only with `inv` again).
`theorem_first_run`: for an accepted, loaded program whose first task
encodes `initial_state`, `inv` holds (from the spec's `theorem_initial`).
`theorem_next_run`: after a preempted or yielded run, a resumed machine
satisfies `inv` again. Since Verus checks that every exec function meets
its precondition (every memory access goes through a view whose
precondition bounds it), this means: for any number of runs and steps,
the core never fails a view bounds precondition and never takes a fatal
path, given the contracts of TRUSTED.md section 6.

The hypotheses of `theorem_first_run` are what the VM establishes before
the core runs a program: at every untrusted launch (and for any program
with -Xverify / TOIT_VERIFY=1) verified/vmverify converts the
`toit_v2_program` tables the core executes into the abstract program and
heap (verified/vmverify/src/from_vm.rs, trusted) and runs the proven
`check::verify` (equal to `accepts`) and `x_loaded_ok` (equal to
`loaded_ok`); the C++ loader no longer checks anything beyond decoding the
method headers. What stays trusted for the first run: that conversion,
`prepare_process_v2` building the initial frames (`initial_state`), and
`toit_v2_run` filling `Program` from the same tables.

Accepted programs. The verified handlers are only correct for accepted
programs; a format-2 program that the launch did not verify (a trusted
program without -Xverify) runs on the checked handlers. Found by
tests/sandbox/runtime-hardening-test, which crashed the core with a
patched LOAD_METHOD operand of an unverified trusted program before the
flag existed.

Launch-time verification cost (time, memory, code size of the verifier
linked into the VM): verified/vmverify/README.md, "Cost".
