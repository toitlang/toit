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
- When a process group is created for a format-2 program,
  `V2MethodTable::compute` (src/interpreter_v2.cc) decodes the method
  headers (note 15) into a table of `V2Method` and checks it: dispatch
  entries are method indices and inside the receiver range of their
  method, every body ends in a terminator and no instruction crosses its
  end, opcodes are valid, this-field accesses are inside the fields of
  every class of the receiver range, branch targets are inside the method
  (forward branches non-zero), and, for untrusted programs, no HALT 2/3.
  A failing program gets no group (`INVALID_SNAPSHOT` /
  `VERIFICATION_FAILED`). For format 2, `Verifier::verify` and
  `verify_for_policy` run these checks (the verified format-2 verifier,
  `check::verify` of verified/spec, is not linked into the VM yet: open).
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
  stack, frame records, top, frame top, bci); on return it holds the
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

Inside, `machine::run` executes `Machine::step` in a loop. `step` checks
the instruction lies in the method (one comparison `bci < mend - 6` in the
common case, the exact check otherwise) and dispatches on the opcode; each
handler follows the spec function of the same name, and every stuck state
of the spec is a run-time check that ends the process (`Ctl::Stuck`).

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
array index:  0 .............. ftop        top ................. len-1
              [ frame records ][   free   ][ object stack, top first ]
```

- Object stack: `array[top..len)`, growing down; object-stack position
  `i` (counted from the bottom) is `array[len - 1 - i]`, so positions
  survive growth and shrinking. Holds only smis and heap references; the
  GC visits exactly `[top, len)` (`Stack::roots_do`).
- Frame records: `array[0..ftop)`, growing up, 4 words each (method
  index, return bci, base = object-stack position of the first argument,
  handler = 0 or `height | bci << 32` of the frame's TRY). No object
  references, so the GC never looks at them. The Stack header's try-top
  word holds `ftop`, the pending-stack-check word the bci.
- Room: before every call the core requires
  `FRAME_WORDS + global_max_height + STACK_RESERVE` free words between the
  two stacks and otherwise grows the stack (`toit_v2_grow_stack`: a new,
  larger Stack, frames copied to the bottom and the object stack to the
  top). Growth past `Stack::max_length()` throws `STACK_OVERFLOW`.
- Shrinking (GC, `Stack::roots_do`) moves the object stack down and keeps
  the frame records and the reserve.
- Block references are smis `frame << 20 | slot` (slot = object-stack
  position); `Stack::max_length() < 2^20` is checked by the layout check.

## 4. FFI contract

Every C++ function the core calls (src/interpreter_v2.h), with the
precondition the core discharges. "MAY GC" functions take the stack view
by `&mut` and replace it; before each the core stores top, frame top and
bci into the Stack object (`Machine::save`), after each it re-derives all
cached state from the current task's stack (`Machine::reload`, which also
re-checks top, frame top and length).

| Function | MAY GC | Precondition discharged by the core | Result |
|---|---|---|---|
| `toit_v2_current_stack(process)` | no | process is the running process | the current task's Stack |
| `toit_v2_allocate_instance(process, class_id)` | yes | `class_id < class_bits.len()`, its tag is instance, state saved | instance with null fields, or 0 |
| `toit_v2_allocate_double(process, bits)` | yes | state saved | double, or 0 |
| `toit_v2_allocate_array(process, length, filler)` | yes | filler is a smi, null or a program-heap object (survives GC); state saved | array, or 0 (also for length > max) |
| `toit_v2_allocate_exception(process, value, kind, words, count)` | yes | value is a program-heap object (failure literal or root); `count <= 4`; the words are read only before the first GC point; state saved (the trace is encoded from the saved stack) | `Exception_` with trace, or 0 |
| `toit_v2_grow_stack(process, needed)` | yes | state saved | OK, STACK_OVERFLOW or OUT_OF_MEMORY; on OK the task has a new stack with `needed` free words |
| `toit_v2_lookup_primitive(process, module, index, &entry, &arity)` | no | none (bounds-checked in the policy) | FOUND or MISSING |
| `toit_v2_call_primitive(process, entry, arity, first, &result)` | yes, may switch task | `entry` came from lookup; `arity` equals the primitive's arity and the method's; the arguments are object-stack positions `first..first+arity` of the current frame; state saved | SUCCESS (result), FAILURE (error value, pushed) or THROW (raise it) |
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
- verified/core/fuzz/fuzz.py: mutates format-2 snapshots, keeps what
  `toit_spec_verify` accepts and runs it untrusted on an ASan build.
- The whole suite with `TOIT_BYTECODE_FORMAT=2` (not required any more,
  still useful): see PROGRESS.md for the current failures and why.
- `TOIT_V2_VALIDATE=1` (debugging aid) checks every object-stack slot of
  every live task before and after each GC and at run entry and exit.

## 8. Measurement tables

(Filled in by the measurement run; see PROGRESS.md for the date.)
