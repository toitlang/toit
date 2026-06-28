# Host bytecode debugger

The host (POSIX) Toit VM has an in‑image bytecode debugger: a breakpoint /
single‑step mechanism in the interpreter plus a controller that speaks the
line‑based `dbg:` protocol over stdin/stdout. It lets an operator set
breakpoints, step, and inspect live frames of a program running under the host
VM.

This document is the in‑repo reference for the VM side. The operator‑facing
tooling — the `jag debug` CLI and its `--web` browser UI, which resolve method
**names**, source **lines**, and class **names** offline from the snapshot — lives
in the `jaguar` repo (`docs/debug_spec.md` / `docs/debug_design.md` there). The
`dbg:` protocol mirrors the OEVM reference debugger so a Toit node can be debugged
like the OEVM node.

## Enabling it

The debugger is active only when debugging is requested: the `--debug` flag on the
inner runner (`toit.run --debug <snapshot>`) or the `OEVM_DEBUG` / `TOIT_DEBUG`
environment variable. When off, the only cost on the bytecode path is a single
predicted‑not‑taken branch on a `false` flag — **zero measurable overhead** when
not debugging (a hard design constraint).

Debug a **pre‑compiled snapshot**, not raw source. Bytecode indices (`bci`) are
program‑relative and the runtime interleaves several programs (privileged system,
services, and under `toit run` the compiler); debugging a snapshot means only the
target app + system run, so breakpoints can key on `(program, method‑id, offset)`.

## The `dbg:` protocol

Line‑based, newline‑delimited, over the VM's stdin (requests) and stdout
(responses). Response lines are interleaved with the program's own stdout; the
operator splits on `\n` and distinguishes protocol lines by the `dbg:` prefix.

**Requests** (operator → VM):

| Request | Meaning |
|---|---|
| `dbg:methods` | list the target's methods |
| `dbg:break <id> <off>` | set a breakpoint at method `id`, offset `off` |
| `dbg:clear <id> <off>` | clear that breakpoint |
| `dbg:continue` | resume the parked process |
| `dbg:step` / `dbg:over` / `dbg:out` | single‑step (into / over / out) |
| `dbg:inspect [frame]` | dump a parked frame's registers (default frame 0) |

**Responses** (VM → operator):

| Response | Meaning |
|---|---|
| `dbg:ready` | the controller is up; emitted once before the program runs |
| `dbg:ok <verb>` | acknowledges a request |
| `dbg:paused break <id> <off>` | hit a breakpoint at method `id`, offset `off` |
| `dbg:paused step <id> <off>` | stopped after a step |
| `dbg:stack off=<bci> r0=<v> r1=<v> …` | a frame's registers (answer to `inspect`) |
| `dbg:error <msg>` | error (e.g. unknown method id) |

The VM emits **numeric method ids only**; ids are 1‑based, assigned by
`dbg:methods` in dispatch‑table order, and stable for the session. Names, source
positions, and class names are all resolved **offline** from the snapshot by the
operator tooling — the wire protocol stays "VM numeric, names resolved offline".

After `dbg:ready`, the VM forces a pause at the first non‑privileged program's
entry (`dbg:paused break -1 0`) so the operator can install breakpoints before the
program makes progress.

## Architecture

Three layers, with a deliberate thread split (`src/debugger.{h,cc}`,
`src/interpreter*.{h,cc}`, `src/scheduler.{h,cc}`):

1. **Interpreter mechanism.** For every bytecode of a non‑privileged process,
   `should_break(program, bci)` is checked (gated behind the debug‑active flag). On
   a hit — a matching breakpoint, or any bytecode while stepping — the interpreter
   stores the stack and returns a new `Result::DEBUG_PAUSED`.
2. **Scheduler park/resume.** On `DEBUG_PAUSED` the scheduler **parks** the process
   (does *not* re‑ready it) and calls `register_paused`. `resume_debug_process(pid,
   step_mode)` re‑readies it later. While debugging, the scheduler is capped to a
   single worker thread.
3. **Controller thread.** A dedicated OS thread (not a scheduler worker, so it may
   block on stdin) reads `dbg:` commands, mutates the breakpoint table, walks the
   parked stack for `inspect`, and resumes the target. The debugger's state is
   guarded by a mutex; a condition variable hands pause/target events between the
   scheduler thread and the controller.

**Why park instead of run‑to‑completion or block in place:** a breakpoint must
suspend just the target process without blocking a scheduler worker (the spike
proved an in‑worker block deadlocks the VM). `DEBUG_PAUSED` + a separate controller
thread is the mechanism.

Stepping carries a mode on resume (1 step / 2 over / 3 out) plus the frame depth at
the pause; `should_break` then stops on the next bytecode (step), at `depth ≤
start` (over), or `depth < start` (out). The `is_privileged` guard keeps stepping
out of system/service frames.

## Register values

`dbg:inspect` answers with `dbg:stack off=<bci> r<slot>=<value> …` for the parked
frame. `emit_stack` formats each register by type so the operator sees real values:

- `null`, `true`, `false`; integers (smi) and doubles as numbers.
- Strings via `emit_string`: a double‑quoted, escaped token (`\" \\ \n \r \t`,
  `\xNN` for control chars), capped at 128 chars — so a value with spaces stays
  whitespace‑delimited on the wire.
- Any other heap object: `<obj:<class_id>>`, the **numeric** class id. The operator
  resolves the id to a class name offline (see the dumps below).

Local variable **names** are not available — registers are raw stack slots. Named
locals would need compiler‑emitted local metadata (out of scope).

## Offline snapshot dumps (`tools/toitp.toit`)

The operator resolves the VM's numeric ids against the snapshot via three
subcommands of `toit tool snapshot`:

- `bytecodes` — per‑method blocks with names + entry bci (method‑name resolution).
- `positions` — one line per bytecode, `<absolute_bci> <path> <line> <col>`, where
  `absolute_bci = method.entry_bci + off`. `<path>` is the compiler's error‑path:
  the user file's path as compiled, `<sdk>/…` for the SDK, `<pkg:..>/…` for package
  files. Drives source‑line highlighting and gutter→breakpoint mapping.
- `class-names` — `<class_id> <name>` per line (from `program.class-tags` /
  `program.class-name-for`), resolving the `<obj:<class_id>>` register markers.

Keeping resolution offline keeps the VM change minimal and matches `jag decode`.

## Tradeoffs & constraints

- **Zero overhead when off** is a hard constraint — the per‑bytecode hook is a
  single branch on a flag that is false unless debugging.
- **Snapshot, not raw source** — required for stable, program‑relative bci.
- **stdin ownership** — the debug channel owns the VM's stdin; a debugged program
  that itself reads stdin is unsupported (matches OEVM).
- **Target selection** — the debuggee is the first non‑privileged program whose
  `Program*` differs from the system program. Multi‑app would need an explicit
  debuggee marker.
- **Single worker thread under debug** — avoids cross‑thread pause hazards; the
  host has ample CPU, so this is a non‑issue for the host path.
- **Tasks** — a breakpoint parks the whole process, so it is task‑aware: it stops
  in whichever task runs the code, once per task per pass, and `inspect` reads the
  paused task's stack. But the step/over/out depth is tracked against a single
  task's stack, so **stepping over a `yield`** (a cooperative task switch) loses
  the stop condition and runs to completion — the same class as stepping over an
  exception unwind. Breakpoints (not single‑stepping) are the way to debug across
  task switches.

## Out of scope / deferred

- **In‑image protocol loop.** The controller is C++. Porting the `dbg:` loop to a
  Toit "debug supervisor" process (via `primitive_debug.cc` primitives) is the
  natural shape for a later device/ESP32 phase, where there is no separate OS
  thread. Not built for the host MVP.
- **Device/FreeRTOS.** The debugger is host‑only today (a POSIX controller thread on
  stdin). Device debugging needs the in‑image supervisor and new VM primitives.
- **Named locals**, conditional breakpoints, watchpoints, expression evaluation
  beyond `inspect`, and DAP/editor integration are out of scope.

## Build & run

```bash
# Build the host VM/SDK after changing src/debugger.cc (or .h):
cd build/host && ninja sdk/bin/toit
# After changing tools/toitp.toit (a Toit tool compiled into the snapshot):
cd build/host && ninja generated/toit.snapshot sdk/bin/toit   # ninja, not make
```

Run a snapshot under the debugger directly with
`build/host/sdk/lib/toit/bin/toit.run --debug <snapshot>` and drive it over stdin,
or — the ergonomic path — use `jag debug` from the `jaguar` repo, which compiles,
launches, and relays for you.

`tools/debug/` holds the original Python proof‑of‑concept driver that validated the
protocol end to end; `jag debug` is its first‑class replacement.
