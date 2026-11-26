# The verified core: design

The Rust interpreter core for bytecode format 2 (verified/spec/format),
running whole processes inside the C++ Toit VM on x86-64 (Phase 4 of
07-verified-sandbox-plan.md). Untrusted containers run on it; trusted
containers and the system process stay on format 1 and the C++
interpreter. Status and next steps: PROGRESS.md. Proof status:
OBLIGATIONS.md. Trusted base: TRUSTED.md and verified/TRUSTED.toml.

## 1. Format dispatch

- A program is format 2 iff its bytecodes start with the tag `TBC3`
  (`Program::is_format2`; the core's format, version 3 since format
  note 23; `TBC` with another digit is a stale image, refused where
  programs start, `Program::has_stale_v2_tag`). The compiler emits format 2 by default on
  builds with the core (docs/format2-migration.md; format 1 with
  `-Xbytecode_format=1`, `TOIT_BYTECODE_FORMAT=1` or a build configured
  with `-DTOIT_BYTECODE_FORMAT=1`), and always for `--untrusted`.
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
  `-Xverify`/`TOIT_VERIFY` (trusted rules) or in debug builds.
  Experiment (EXPERIMENT-trusted.md): unverified, they too run on the
  verified loop, with the trusted token (`TOIT_V2_TRUSTED`) and in the
  unchecked mode (`Program2::unchecked`). `TOIT_TRUSTED_CHECKED_LOOP=1`
  puts them back on the checked loop, where the core's run-time checks
  catch every stuck state.
- `Interpreter::run` and `prepare_process` hand format-2 processes to
  `run_v2` / `prepare_process_v2`; the scheduler is unchanged (it calls
  `Interpreter::run` as before). `load_stack`/`store_stack` are no-ops for
  format 2: the core keeps the stack object up to date itself.
- Untrusted containers must be format 2: programs-registry spawn and
  snapshot launch refuse a format-1 program under the untrusted policy
  with `FORMAT_2_REQUIRED`, and so does the install of an image flagged
  untrusted. **Every build: format 2 required** (the flag
  `-Xuntrusted_format1` / `TOIT_UNTRUSTED_FORMAT1=1`, which ran untrusted
  format-1 programs on the C++ interpreter, was removed).
- With the CMake option `TOIT_VERIFIED_CORE` off (default off for
  embedded and cross builds, or without cargo) the VM builds without the
  core and refuses to run format-2 programs, and so every untrusted
  container. It is on by default for
  64-bit hosts and for 32-bit x86 Linux hosts (toolchains/host32.cmake:
  Rust target `i686-unknown-linux-gnu`); ESP32-C6/H2 firmware gets it with
  the menuconfig option `TOIT_VERIFIED_CORE` (Rust target
  `riscv32imac-unknown-none-elf`, no_std, PROGRESS.md "Phase 5").

## 2. Run-loop contract (`toit_v2_run`)

`Interpreter::run_v2` fills a `toit_v2_context` (program tables, globals,
heap range, remembered-set bias, `&watermark_`, flags) and calls
`toit_v2_run`, which owns the run loop of the process until it returns,
with the contract of `Interpreter::run`:

- On entry the current task's Stack object holds the task state (object
  stack, frame records, top, frame top and bci); on return it holds the
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

Register allocation (section 2a): the verified loop keeps the hot state in
registers (`regs::Regs`), the rest of the machine behind a pointer.

## 2a. The run loop on registers (`step::run_loop`, `regs.rs`)

- `Regs` holds stack cursors (`view::Slot`, a pointer into the Stack's
  array whose ghost index is `s@`) at the object-stack top (`sp`), the top
  frame's limit (`fp`), the frame-record top (`fr`) and the array end
  (`end`), and the instruction pointer (`Ip`, a cursor into the bytecodes:
  an operand is one load relative to it; the bci, an index, is computed
  only where it is stored, for the return address of a call). It is a
  local of `run_loop`; inlined handlers take
  it by `&mut` (its address never escapes, so LLVM keeps the fields in
  registers), out-of-line paths take and return it by value
  (`regs::set_regs` copies a returned value field by field). Everything
  else (the views, the length, the fast paths' constants, the ghost state)
  is the
  `Machine` behind `&mut`. Slot `n` is `sp[n]`: one load relative to the
  top.
- Abstraction: the machine's fields `top`, `lim`, `base`, `ftop`, `bci`
  and `method` are stale while the loop runs; `m.with(r)` is the machine
  the registers describe (the top frame's method the method word of its frame record, so calls and
  returns store no method), and the abstraction of the pair is
  `m.with(r).refines(p)`: the refinement relation of section 9 unchanged.
  `m.sync(r)` writes the registers back, `m.enter(p)` sets the fast
  paths' constants and derives them. Every register handler proves `rpost`: on `Next`,
  `m1.with(r1)` refines the spec's next state (`step_post` of the machine
  form), plus the room and the constants.
- Dispatch: `step_r`, one `match` arm with a constant opcode per opcode
  (no range patterns: they cost a second switch) and a default arm proven
  unreachable, so LLVM duplicates the 6-instruction dispatch into the
  handlers (`-tail-dup-size=12`; 120 dispatch sites). The VM's Rust library
  is compiled without the SLP vectorizer (verified/vmverify/.cargo/
  config.toml): it packed pairs of registers into one vector register and
  unpacked them at every dispatch.
- One body per opcode (branch core/size-diet): every opcode has exactly
  one handler, its register handler. Where its fast path does not apply
  (before it changes anything), it calls `step::slow` (out of line, one
  copy for all sites) with what the machine's code needs (`step::Slow`):
  `slow` writes the registers back, runs the shared machine-form code and
  derives the registers again (`step::resume`: the room, then
  `Machine::enter`). The machine-form code is what is cold or rare: the
  raises (`Raise`, `Invalid`, `As`, `Lookup`: `raise.rs`, one copy of each
  message), calls with stack growth or preemption (`Call`:
  `step::ensure_room`, `Machine::push_call`), returns of the bottom frame
  (`Return`:
  `Machine::do_return`), the C++ primitives (`Prim`:
  `primitive::op_primitive_cxx`) and the whole handlers of the opcodes in
  `step::machine_op` (`Op`: LOAD_GLOBAL_VAR_LAZY(_WIDE), the tail calls,
  INVOKE_BLOCK, THROW, NON_LOCAL_RETURN, NON_LOCAL_BRANCH, TRY, UNWIND,
  HALT; their register handlers have fast paths for the common cases where
  they exist, and `step::step_machine` dispatches the rest). The machine's
  step over all opcodes (`step_m`, 25 KB on devices) and the machine
  handlers that duplicated the register handlers are gone.
- Try/finally in the register loop (format note 23): TRY is a block call
  under the call's fast-path check (`rnonlocal::op_try`; the check keeps one
  word of slack, `need`, because TRY pushes the block reference before
  the call); a return tests the returning frame's handler word and, for a
  try block, enters its caller's finally code out of line
  (`rnonlocal::ret_try_v`); UNWIND pops the four slots when token word B
  is the smi 0 (a normal completion) and otherwise resumes a non-local
  return or branch on the registers (`unwind_resume_v`, exceptions on the
  machine). A non-local return or branch that meets a try block on the
  way enters its caller's finally code on the registers too
  (`rnonlocal::pop_to` stops there, `enter_fin_r` pops it and pushes the
  four slots). The finally slots are within the frame's room (the
  verifier counts them in the TRY's successor map), so none of these paths
  rescans the room (`room::room_ok`: every frame's). After a machine path
  that kept the frames below the top (a call, a return, an unwinding)
  `step::top_room_kept` checks the top frame only; `resume` scans every
  frame after the others (branch experiment/trusted-fast). Until format 3
  the finally records followed the frame records and moved on every call
  and return in finally code (rfins.rs and a gate that made those calls
  and returns fail their fast paths).
- Preemption at calls is merged into the room check, as the C++
  interpreter merges it into its stack-limit check: a call takes the fast
  path iff `free >= (watermark | need)`; the watermark is null while the
  core runs and all ones when preemption is requested, so a request sends
  the call to `slow`, whose `push_call` preempts at the callee's entry as
  before. Any other watermark value only makes the check stricter
  (`(w | n) >= n`, `rcalls::lemma_or_ge`), so the room proof does not
  depend on it. Backward branches test the watermark as before.
- GC points inside register handlers (ALLOCATE, double arithmetic) write
  the registers back, run the machine-form code and re-derive them with
  `room::regain`.

## 3. Stack layout

The task's existing `Stack` heap object holds both stacks, so stack
growth, GC root scanning and C++ primitives work as before:

```
array index:  0 ........... ftop          top ............. len-1
              [ frame records ][  free  ][ object stack, top first ]
```

- Object stack: `array[top..len)`, growing down; object-stack position
  `i` (counted from the bottom) is `array[len - 1 - i]`, so positions
  survive growth and shrinking. Holds only smis and heap references; the
  GC visits exactly `[top, len)` (`Stack::roots_do`).
- The layout is the same for 32-bit and 64-bit words (Phase 5): every
  value packed into a word fits 32 bits. Stacks are shorter than
  `MAX_STACK_LENGTH` = 2^16 words (`Stack::max_length()` is about 4,000
  words on 64-bit hosts, 8,000 on 32-bit hosts and 1,000 on devices;
  checked by the layout check, re-checked by `reload`), so stack
  positions, heights and record indices fit 16 bits; bcis need 28 bits and
  get a word of their own.
- Frame records: `array[0..ftop)`, growing up, `FRAME_WORDS` = 4 words
  each (method index, return bci, base = object-stack position of the
  first argument, and the handler word: 1 for a try block, 0 otherwise;
  format note 23), frame `fi` at `4 * fi` (block references and C++ rely on
  that). A try block's return, or an unwinding that pops it, continues the
  frame below at the try block's return bci with the object stack cut to
  the try block's base, the finally code's four slots pushed (`calls.rs`
  `enter_finally_v`, `rnonlocal::enter_fin_r_opt`). Until format 3, step 3
  the word was the height of the frame's own TRY (and until step 2 a fifth
  word held the handler's bci).
- The pending unwinding of a finally code is in its two token slots (the
  object stack: value, token word A, token word B, reason): A is the target
  frame and height of a non-local return or branch as a block reference's
  word, B is `bci * 4 + kind` (`abs::token_a`, `token_b`). There are no
  finally records (format note 17's records followed the frame records and
  moved on every call and return in finally code). The Stack header's
  try-top word holds the frame top, the pending-stack-check word the bci.
  C++ reads them through `Stack::v2_frame_top()` and `v2_bci()`; the
  format-1 paths that use `try_top()` directly never see a format-2 stack
  (the GC's shrinking and `v2_copy_to` keep `[0, v2_frame_top())`).
- Room: before every call the core requires
  `FRAME_WORDS + global_max_height + STACK_RESERVE` free words between the
  frame records and
  the object stack and otherwise grows the stack
  (`toit_v2_grow_stack`: a new, larger Stack, records copied to the bottom
  and the object stack to the top). Growth past `Stack::max_length()`
  throws `STACK_OVERFLOW`. The verified loop's invariant carries the room
  (`room::room_ok`): every frame `i` can grow to its method's arity plus
  the global maximal height (the verifier's bound on every frame's height,
  `instr_ok`, which covers a TRY's finally slots) and leave `STACK_RESERVE`
  words above the frame records up to `i`:
  `base_i + arity_i + max_height + 4 (i + 1) + 8 <= len`. A call
  checks once (the line above) and so establishes the new frame's room;
  returns and pops keep it; the top frame then always has at least
  `STACK_RESERVE` free words (`room::lemma_room_top`), so no push is
  checked. Per-method maximal heights would make the bound tighter (less
  stack memory), not the check cheaper; the format's global height is
  enough. What breaks the room: a GC that shrank the stack (the shrink in
  `Stack::roots_do` keeps room only above the current top) and a task
  switch. After those,
  `room::ensure_room_all` scans the frame records and grows the stack if needed (a GC point that keeps
  the state; failing growth stops with `LIMIT`, out of memory); after a GC
  point a register handler only scans when the length shrank
  (`room::regain`), and `step::resume` checks after every path on the
  machine. The machine's code (checked loop and slow paths) keeps its own
  run-time checks.
- Shrinking (GC, `Stack::roots_do`) moves the object stack down and keeps
  the records and the reserve.
- Task switches: a suspended task's frame records and object stack (with
  any pending unwinding in token slots) stay in its Stack object; a new
  task starts with no frames.
- Proofs: `Machine::refines` relates the frame records to `State2.frames`
  (`abs::frames_rel`, the handler word to `Frame::handler`) and the token
  words to `Value::Token` (`abs::enc`). Calls, returns (`calls.rs`:
  `push_call`, `pop_frame_v`, `do_return`, `enter_finally_v`) and THROW, TRY, UNWIND, NON_LOCAL_RETURN and
  NON_LOCAL_BRANCH (`unwind.rs`, one inlined unwinding loop for all of
  them) is verified; machine.rs keeps checked copies for
  programs not accepted at launch (the checked loop), which must stay in
  step with the verified ones.
- Block references are smis `frame << 16 | slot` (slot = object-stack
  position below 2^16, frame below 2^16 / 4 = 2^14: the smi is below 2^30
  and fits 31-bit smis); `Stack::max_length() < 2^16` is checked by the
  layout check.

## 3a. Word size (Phase 5)

The core builds for 64-bit and 32-bit targets from the same source and
Verus verifies it for both (verified/check.sh: the host, and
`--target i686-unknown-linux-gnu` with Verus' support libraries built for
that target by verified/tools/verus_target.sh). Verus fixes the width of
`usize`/`isize` from `global size_of usize` (abs.rs, one per
`target_pointer_width`), so every proof about words, overflow and casts is
checked at the width the code runs with. What differs per width is only
in layout.rs (`WORD_SIZE`, `WORD_BITS`, `MIN_SMI`/`MAX_SMI`, the string
and byte-array offsets, `CARD_SIZE_LOG_2`) and `abs::MAX_BLOB_LENGTH`;
`prog_rel` requires the abstract program's `word_bits == WORD_BITS`, so the
spec's smi range (`smi_ok` with `word_bits`) is the machine's. Smi values
stay `i64` on both widths (decoding is the arithmetic shift of the word as
an `isize`, `abs::smi_value`); the smi fast paths of ADD, SUB and MUL check
the overflow of the tagged word as an `isize`; shifts compute in `i64`.
Doubles and large integers keep their 64-bit payload (two words on 32-bit,
read unaligned: `view::Heap::double_bits`, `large_int`, `word64`). The
spec's primitive contracts state `Primitive::integer`'s smi range per
target (`prim_core::smi_in`). The format-1 VM's half-word string fields
are `view::HalfWord`.

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
| `toit_v2_grow_stack(process, needed)` | yes | state saved | OK, STACK_OVERFLOW or OUT_OF_MEMORY; on OK the task has a new stack with the frame records copied and `needed` free words above them |
| `toit_v2_lookup_primitive(process, module, index, &entry, &arity)` | no | none (bounds-checked in the policy) | FOUND or MISSING |
| `toit_v2_call_primitive(process, entry, arity, first, &result)` | yes, may switch task | `entry` came from lookup; `arity` equals the primitive's arity and the method's; the arguments are object-stack positions `first..first+arity` of the current frame; state saved | SUCCESS (result), FAILURE (error value, pushed) or THROW (raise it); after a task switch the new task's Stack holds its frame records (none for a new task) |
| `toit_v2_report(process, kind, bci, detail)` | no | none | message on stderr |

The C++ primitive path is unverified and outside the security boundary
(TRUSTED.md section 2). Ported primitives: src/prims (TRUSTED.md section
8, PROGRESS.md "Primitives"): the verified PRIMITIVE handler runs the
Rust port (`prims::call`) of a core primitive when the policy's verifier
table (`toit_v2_context::policy_arities`, `Program::policy`) allows it
(a table lookup, no C++ call; a denied primitive completes with
PERMISSION_DENIED, an absent one with PRIMITIVE_LOOKUP_FAILED, in the
core), without saving and reloading the machine (no GC point); their only
C++ helpers are `toit_v2_try_allocate_*` (no GC). `NotPorted` and
`NeedsGc` (heap unchanged) fall back to lookup and call above, which
collect and retry. 106 of the 143 allowed primitives of
docs/sandbox-policy.md run in Rust for untrusted programs; the other 37
and everything trusted programs on the checked loop call stay C++. Timer
and event glue stays C++ (it is reached through primitives and the
scheduler).

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
- verified/tools/untrusted_suite.toit: every program the reference
  interpreter can run (run_suite.toit status `pass` or `steplimit`) runs
  untrusted in format 2 and trusted in format 1; stdout and exit code
  must match.
- verified/tools/core_fuzz.toit: mutates format-2 snapshots, launches each
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

### After the proof half (2026-11-10, branch core/refinement)

Verified loop (accepted programs; the benchmarks run with TOIT_VERIFY=1,
which verifies them at launch). Ir counted inside the interpreters only
(callgrind `--toggle-collect` of `toit::Interpreter::run` resp.
`toit_v2_run`, callees such as GC and primitives included; startup and
launch verification excluded). Wall: per-iteration time, minimum of 5,
machine load about 7 (noisy: two runs gave richards 1.73 and 1.98).
"before" is the core at sandbox-integration 18588de3 measured on the same
build.

| Benchmark | f1 Ir | f2 Ir before | f2 Ir after | ratio before | ratio after | wall f2 before ms | wall f2 after ms | wall ratio after |
|---|---|---|---|---|---|---|---|---|
| richards | 1,024 M | 4,029 M | 2,495 M | 3.94 | 2.44 | 25.1 | 18.6-19.4 | 1.7-2.0 |
| deltablue | 650 M | 2,725 M | 1,897 M | 4.19 | 2.92 | 18.4 | 14.9-15.1 | 2.3-2.5 |
| pystone | 762 M | 2,669 M | 2,189 M | 3.50 | 2.87 | 17.8 | 17.5-17.7 | 2.3-2.6 |

Where it came from: the removed checks (instruction in method and the
`mend`/`mfast` cache, slots, indices, branch targets, arity, lookup
ranges, the `this` field checks, block reference decoding), and keeping
the checked dispatch out of line on slow paths (inlining a copy of it at
each slow path had cost 14% on richards). Programs not accepted run the
checked loop, which is now slower than before (5,280 M on richards: no
`mfast` cache any more); only unverified trusted format-2 programs use it.
pystone gains little wall time although its instruction count fell 18%:
its double arithmetic takes the slow path, which copies the machine into
the out-of-line checked dispatch (`cold!`) and redoes the decoding; the
double fast paths (verified, with a double heap accessor) are the next
step. Raw numbers: /home/flo/work/opentoit-sandbox-artifacts/core-refinement/.

### After the second proof pass (2026-11-10, branch core/refinement-2)

Same method as above (callgrind inside the interpreters, TOIT_VERIFY=1):

| Benchmark | f1 Ir | f2 Ir | ratio | ratio before this pass |
|---|---|---|---|---|
| richards | 1,024 M | 2,420 M | 2.36 | 2.44 |
| deltablue | 650 M | 1,782 M | 2.74 | 2.92 |
| pystone | 762 M | 1,772 M | 2.33 | 2.87 |

pystone gains most: its double arithmetic and comparisons are now the
verified inline paths (before: the out-of-line checked dispatch), and
list accesses (deltablue) no longer leave the loop. Where richards' 34
instructions per bytecode go (callgrind lines, run_loop inlined): the
dispatch `match` about 12 percent of all instructions, program-table reads
(`Table::at`: bytecodes, method table, dispatch table) 11.6 percent, stack
reads 5.4 percent, the loop head with the `Ctl` result and the unwinding
code inlined once about 16 percent; the C++ interpreter needs about 14 per
bytecode. Program tables are still read through `env.p` and the table
pointer, reloaded after stores through the stack's raw pointers (which
LLVM cannot prove disjoint from the `Program`). The next steps are
unchanged (top/bci in locals, table pointers as run-loop arguments with
`noalias`, tail-call threading). HASH_FIND and REPEAT built-ins (notes 16,
11) were not added: they would remove the bytecode-level loops of
`Map`/`Set` lookups and `int.repeat` (format 1's intrinsics).

### Performance pass (2026-11-11, branch core/prims-integration)

Instructions inside the interpreters (callgrind `--toggle-collect`,
format 1 trusted without verification on the C++ interpreter, format 2
with TOIT_VERIFY=1 on the verified loop; scripts and raw numbers in
/home/flo/work/opentoit-sandbox-artifacts/prims-integration, `ir.sh`,
`ir/results.txt`, `ir/notes.txt`). Each step was kept only if it helped;
`verified/check.sh` stays green (no proof changed except the default arm
below).

| Step | richards | deltablue | pystone |
|---|---|---|---|
| format 1 | 1,024 M | 650 M | 762 M |
| start (part 1, Rust primitives) | 2,420 M (2.36) | 1,751 M (2.69) | 1,724 M (2.26) |
| 1. dispatch: one jump table, no range check | 2,208 M | 1,611 M | 1,571 M |
| 2. `Env` owns the `Program` (table pointers hoisted) | 2,174 M | 1,565 M | 1,526 M |
| 3. tail-duplicated dispatch (`-tail-dup-size=12`) | 2,097 M (2.05) | 1,513 M (2.33) | 1,446 M (1.90) |

1. Dispatch. The opcode `match` had range patterns (`14..=19`, `78..=80`,
   `81..=84`, `85..=88`), which rustc lowers as comparisons in the jump
   table's default: LOAD_LOCAL_0..5, the most frequent opcodes, took the
   table, a range test and a second jump. Explicit alternatives put every
   opcode into the table (-6.3 % on richards). The default arm is proven
   dead; `view::proven_unreachable` (`requires false`,
   `unreachable_unchecked`, TRUSTED.md section 4) lets LLVM drop the range
   check before the table (-2.7 %).
2. Table pointers. The loop read the tables through `env.p`, a pointer
   loaded from `Env`; LLVM could not prove the `Program` disjoint from the
   stack's raw pointers and reloaded the table pointers after every stack
   store. `Env` now holds the `Program` by value, so the loop's `&Env`
   (noalias, readonly) covers them and they are loop invariant. No trusted
   change (the views are the same; only their owner moved).
3. Threading. Stable Rust 1.99 has no guaranteed tail calls (`become` is
   nightly-only), and a handler-per-opcode function table would need
   Verus specs for function pointers, which it does not support for this
   use; so the dispatch stays a verified `match`. LLVM's tail duplication
   (raised from its default with `-C llvm-args=-tail-dup-size=12` in
   verified/vmverify/.cargo/config.toml) copies the 6-instruction dispatch
   (bci load, opcode fetch, table load, jump) into the handlers: 2 dispatch
   sites become 40 and the jump back to the shared block disappears.
   Sizes 8, 12, 20: -3.2, -3.6, -4.0 % on richards; 12 was kept.

Tried and dropped (`ir/notes.txt`): `panic = "abort"` for the VM's Rust
library (no change: unwinding does not block register promotion);
inlining `run_loop` into `machine::run` (no change) and additionally
dropping the `black_box` of the machine fields (+1 %: the table pointer
gets a register but `bci` stays in a stack slot); inlining the three
out-of-line verified functions that take `&mut Machine` (`grow`,
`raise_with`, `op_primitive`) so that the whole machine is promoted to
registers (+13 %: a 220 KB function that spills everywhere, as the
first performance pass found).

The loop head is now the fetch and jump only: the preemption check is
already where the C++ interpreter has it (after a call has set up the
callee's frame, and at backward branches), not per instruction.

Where the remaining time goes (richards, 2,097 M, 71.6 M bytecodes, 29
instructions each; the C++ interpreter needs 14 per format-1
bytecode): the dispatch (the `match` with its tail copies and the `bci`
load: about 12 % plus 3.4 %), stack slot reads and writes through
`StackMem` (8.8 %), program-table reads (5.7 %, now direct), the push room
check (`top <= rtop`, 3.9 %: the verifier bounds the frame height, but
the machine invariant does not carry the room yet, so the check is
needed for the proof), calls and returns (`push_call`, `do_return` with
the finally-record cut: 11 %), field accesses with their program-heap
check (6.9 %). The largest structural cost left is that `bci`, `top` and
the frame cache live in memory: the machine is reached through a pointer
and the cold paths copy it, so every instruction loads and stores `bci`
and `top`. Keeping them in registers needs the handlers to take and
return them (a rewrite of every handler signature and its proof) or a
split of the machine into a register part and a memory part; the
experiments above show that promoting all of it is worse.

Superinstruction candidates and the REPEAT / HASH_FIND estimate:
PROGRESS.md, "Performance pass".

### The loop on registers (2026-11-11, branch core/fast-loop-proven)

Section 2a; progression and what is left: PROGRESS.md. Same method as the
performance pass (scripts and raw numbers:
/home/flo/work/opentoit-sandbox-artifacts/fast-loop-proven, `ir.sh`,
`ir/results.txt`).

| Benchmark | C++ f1 -O3 Ir | before | after | ratio before | ratio after | prototype |
|---|---|---|---|---|---|---|
| richards | 1,023 M | 2,105 M | 1,234 M | 2.06 | 1.21 | 1.09 |
| deltablue | 650 M | 1,520 M | 952 M | 2.34 | 1.46 | 1.44 |
| pystone | 762 M | 1,451 M | 940 M | 1.91 | 1.23 | 1.23 |

Code size of `step::run_loop` alone (the loop with its inlined handlers;
`size.sh`, the core crate at the given opt-level with tail duplication):
x86-64 25.2 KB text + 2.3 KB tables at opt 3 (before 29.0 KB + 0.4 KB),
21.6 + 1.7 KB at opt s (before 25.2 + 0.4); riscv32imac 19.6 KB at opt 3
(before 23.2), 17.5 KB at opt s (before 21.5). Linked into the device
library (riscv32imac, device features: no checked loop, no inference;
verified/vmverify/tests/device_size.sh), "verified loop and cold paths":
54.3 KB at opt 3, 49.5 KB at opt s (before: 41.4 / 38.0 KB, plus the
checked loop 20.8 / 22.7 KB which devices now leave out); the Rust
library in total 107.1 / 99.9 KB (before 114.0 / 110.2). The increase of
the verified part is the machine's step (`step::step_m`, 25 KB, one
out-of-line copy for the bridge and for finally code): the register
handlers duplicate the fast paths of the machine handlers, which stay for
the slow paths and for finally code.

### Size diet (2026-11-11, branch core/size-diet)

Section 2a ("One body per opcode"; the finally records of that time are
gone since format 3, step 3); progression: PROGRESS.md. Device sizes of the Rust library,
riscv32imac, linked with --gc-sections (verified/vmverify/tests/
device_size.sh, device features), text by component in bytes; Ir as in
the previous table (artifacts core-size: `devsize/`, `ir/results.txt`):

| Component | before opt 3 | after opt 3 | before opt s | after opt s | after opt z |
|---|---|---|---|---|---|
| core: verified loop and cold paths | 54,296 | 28,056 | 49,458 | 26,008 | 22,886 |
| of which `step::run_loop` | 19,614 | 19,964 | 17,516 | 18,118 | |
| of which the machine's step `step_m` | 25,060 | 0 | 23,384 | 0 | 0 |
| of which `step::slow` (all slow paths) | - | 2,990 | - | 2,980 | |
| core: primitives | 15,458 | 15,458 | 13,376 | 13,376 | 12,424 |
| verifier: checker + heap check | 19,568 | 19,568 | 19,516 | 19,516 | |
| Rust library total | 107,054 | 80,616 | 99,858 | 76,166 | 71,814 |

| Configuration (whole core) | richards | deltablue | pystone | loop + cold + primitives |
|---|---|---|---|---|
| before, opt 3 | 1,234 M (1.21) | 952 M (1.46) | 940 M (1.23) | 69.8 KB |
| after, opt 3, tail-dup 12 | 1,158 M (1.13) | 913 M (1.40) | 889 M (1.17) | 43.5 KB |
| after, opt 3, no tail duplication | 1,273 M | 989 M | 975 M | 41.6 KB |
| after, opt s | 1,303 M | 1,019 M | 1,021 M | 39.4 KB |
| after, opt z | 1,569 M | 1,202 M | 1,219 M | 35.3 KB |

Recommended for devices: the core at opt 3 with tail duplication (the
default), the verifier at opt z (already a per-package override). Opt s
saves 4.1 KB for 11-15 percent more instructions, no tail duplication 1.9
KB for 8-10 percent; neither pays. Taking `prims::call` (the primitive
dispatch, inlined into the loop) out of line saves 1.5 KB but costs 1-5
percent (register allocation of the loop changes), so it stays inlined.
Wall time (x86-64, load about 24 on 32 cores, minimum of 10): C++ 12.75 /
7.98 / 8.86 ms, before 11.99 / 9.15 / 8.53 ms, after 11.85 / 9.27 / 8.42
ms (0.93 / 1.16 / 0.95 of C++).

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
address in the heap model, block references the smi `f << 16 | slot`,
the words of an unwinding token `token_a`/`token_b`), the object-stack
words are `enc` of `g.stack`, the frame records `mem[4*fi..]` hold
`g.frames` with their handler flags (`frames_rel`), the globals are `enc` of `g.globals`, the heap model is
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
implies is gone. Every opcode and every path is verified: slow paths
(doubles, large integers, `compare_numbers`, every collection of
`fast_at`), tail calls, raising (`Outcome2::Raise` completed by
`prim::raised`), resource throws (`prim::resource_throw`: stack overflow,
out of memory) and PRIMITIVE (`theorem::completion`). A handler of a path
that is one of the spec's alternatives (a raise, a resource throw, a
PRIMITIVE completion) takes `step::source(g, o)` (every completion of `o`
is an outcome of `g`) instead of `step(g) == o`. The C++ calls on these
paths are leaf contracts stated as such outcomes (TRUSTED.md section 6).

Run loop (`src/step.rs`). The loop invariant is `Machine::inv` (refines,
accepted, `wf`) plus `reaches(start, g)`: the state is reached from the
run's start by `advances` steps (the same state, or a state an outcome of
`theorem::outcome` continues in: the spec's transitions without the size
bound). `wf` is re-established after every step from the
spec's `step_ok` (preservation is the verifier's soundness proof).

End-to-end theorem (`src/theorem.rs`). The verified run loop has
`requires inv` and `ensures run_post` (preempted/yielded only with `inv`
again and a state reached from the run's start; the other results end the
process and are not constrained: that a step reports a stuck result only
for the resource limit is `step_post`, internal to the loop).
`theorem_first_run`: for an accepted, loaded program whose first task
encodes `initial_state`, `inv` holds (from the spec's `theorem_initial`).
`theorem_next_run`: after a preempted or yielded run, a resumed machine
satisfies `inv` again. `theorem_process` (`src/process.rs`) composes the
two by induction over the runs of a process. Verus checks that every
verified call meets its callee's precondition (every memory access goes
through a view whose precondition bounds it); `run_loop` itself is called
from plain Rust (`machine::run`), so that its precondition holds on every
run is these theorems plus the trusted glue that establishes `loaded` and
`resumed`. Together: for any number of runs and steps, the core never
fails a view bounds precondition, given the contracts of TRUSTED.md
section 6.

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
program without -Xverify) runs on the checked handlers. The verified loop
takes an `ffi::Accepted` token, built only in `toit_v2_run` when the
context says `TOIT_V2_ACCEPTED`, which `Interpreter::run_v2` writes only
for a `V2MethodTable` the launch-time verifier accepted (marked by
`V2Verifier::verify`'s accept path; under the untrusted rules for an
untrusted process). Found by
tests/sandbox/runtime-hardening-test, which crashed the core with a
patched LOAD_METHOD operand of an unverified trusted program before the
flag existed.

Launch-time verification cost (time, memory, code size of the verifier
linked into the VM): verified/vmverify/README.md, "Cost".
