# C++ VM findings from the spec validation

Phase 2 validation of the executable spec against the C++ VM
(`tests/run_suite.py`, `tests/compare_trace.py`, see DESIGN.md
"Validation at scale"). Each entry: where, what, how to reproduce, and a
suggested fix. Entries are for another agent to turn into upstream PRs.

## Summary

The differential runs (269 runnable tests of the suite in two smi sizes,
1.45 M consecutive bytecodes compared against the debug VM's trace) found
**no new VM bug**: every discrepancy was in the reference interpreter's
primitives or world emulation, and was fixed there. The two bugs the
Phase 0 spec found (MIN_SMI / -1 in INVOKE_DIV and `smi_divide`, the
hash-find REBUILD argument) were already fixed in c5d7adec; the spec now
follows the fixed VM.

The entries below were found while specifying format 2 by reading the
interpreter against the spec. They need crafted bytecode (an untrusted
program does not go through the compiler); they are reachable from
sandboxed containers until the structural verifier or the hardening of
Phase 1 covers them.

## 1. INVOKE_LAMBDA_TAIL trusts the lambda's method id and captures

`src/interpreter_run.cc`, `OPCODE_BEGIN(INVOKE_LAMBDA_TAIL)` (around line
1057).

* `Method target(program->bytecodes, Smi::value(receiver->at(0)))`: the
  method id comes from field 0 of a heap object and is used as a bytecode
  offset without any check, so any smi becomes a jump target (and its
  "header" is read from arbitrary bytecode bytes).
* `captured_size` is the length of field 1 if it is an array (else 1) and
  is not compared with the target's arity. With `captured_size > arity`,
  `user_arity` is negative, `extra = k - user_arity` exceeds `k`, and
  `DROP(extra + 1)` drops words below the receiver, i.e. the caller's
  frame (return address and frame marker) and slots, before pushing the
  captured values: stack corruption.
* No headroom check before pushing `captured_size` values.

Reproduce: a program whose bytecode constructs `Lambda.__ <smi> <array>`
(the compiler refuses `Lambda.__` from user source as a protected SDK
member, so this needs a crafted snapshot or `--force`-free bytecode
editing) and calls it with `.call`.

Fix: validate the id against the method-entry table of the Phase 1
hardening group (or, in format 2, the method table: index, kind LAMBDA),
check `captured_size <= arity` and the stack headroom; raise
`INVALID_PROGRAM` otherwise. Format 2 specifies exactly this
(`v2::spec::op_invoke_lambda_tail`, format/12-heap-method-ids.md).

## 2. INVOKE_INITIALIZER_TAIL trusts the initializer's method id

`src/interpreter_run.cc`, `OPCODE_BEGIN(INVOKE_INITIALIZER_TAIL)` (around
line 685): `Smi::cast(POP())` of a value read from
`LazyInitializer_.id-or-tasks_` (a field Toit code also stores task lists
into); the id is used as a bytecode offset without a check (only the
arity byte at that offset is consulted), and in a release build a
non-smi is reinterpreted.

Reproduce: crafted bytecode that stores a smi (or an object) into a
LazyInitializer_'s field 0 and reads the global.

Fix: check `is_smi` and validate the id against the method-entry table;
raise `INVALID_PROGRAM`.

## Observations (not bugs today)

* `Object::mutable_byte_content` (`src/objects_runtime.cc`) makes an
  immutable `CowByteArray_` mutable by storing a new backing into the
  instance. If such an instance ever lived in the program heap, this
  would write the read-only program heap. The compiler does not put COW
  instances in the program heap (checked on the dumps of the 414 test programs that compile); the program-heap write guard of Phase 1 should cover the path.
* The debug VM's `-Xtrace` output does not say which process a line
  belongs to, and preemption switches processes without a marker line.
  `tests/compare_trace.py` works around it by forcing a single scheduler
  thread (`get_nprocs` preloaded to 1) and resynchronizing on the
  reference interpreter's trace. A process id in the trace line would
  make the comparison exact.
