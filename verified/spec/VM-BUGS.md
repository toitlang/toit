# C++ VM findings from the spec validation

Phase 2 validation of the executable spec against the C++ VM
(`verified/tools/run_suite.toit`, `verified/tools/compare_trace.toit`, see DESIGN.md
"Validation at scale"). Each entry: where, what, how to reproduce, and a
suggested fix. Entries are for another agent to turn into upstream PRs.

## Summary

The differential runs (269 runnable tests of the suite in two smi sizes,
1.45 M consecutive bytecodes compared against the debug VM's trace; see
DESIGN.md for the 2026-11-11 figures) found
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

## 3. The message encoder trusts the fields of lists, list slices and maps

Found by the audit of machine-interpreted objects (SOUNDNESS.md,
2026-11-10). `src/messaging.cc`, reached by `process_send` (allowed for
untrusted programs):

* `MessageEncoder::encode` for a `List_` (around line 179) checks that the
  size is a smi, then `encode_list` -> `encode_array(array, 0, size)`
  reads `array->at(i)` for every `i < size` without comparing `size` with
  `array->length()`: a heap over-read whose words are encoded into a
  message for another process (disclosure, or a crash on a non-object
  word).
* `ListSlice_` (around line 182): `from` and `to` are smis but are not
  checked against the backing's length, and `from <= to` is only an
  `ASSERT` in `encode_array`: same over-read; `to < from` writes a huge
  cardinal.
* `encode_map` (around line 273): `for (i = 0; count < size; i += 2)`
  reads `array->at(i)` with no bound by the backing array: with a size
  larger than the live entries it reads past the array until `count`
  reaches `size`.

Reproduce: crafted bytecode that stores into `List_.size_` (or the slice's
`to_`, or `Map_.size_`) of a small collection and sends it with
`process_send`. Library privacy keeps Toit source from doing it.

Fix: in `encode` for lists require `0 <= size <= backing length`; for
slices require `0 <= from <= to <= backing length` (backing array or list
size); in `encode_map` bound the loop by the backing length and fail if
`count < size` at the end.

## 4. The error encoder trusts a list's size

`src/encoder.cc`, `EncodeVisitor::visit_instance` (around line 115):
for a `List_` whose backing is an array it calls
`visit_list(..., Smi::value(instance->at(LIST_SIZE_INDEX)))` without
`is_smi` and without bounding the size by the backing length; `visit_list`
reads up to 10 elements: a heap over-read (non-object words are then
visited as objects). Reached by the `encode_error` and `encode_object`
primitives (allowed for untrusted programs) and, in format 2, by
`toit_v2_allocate_exception` (`src/interpreter_v2.cc`), which encodes the
message words of a raised failure, e.g. the receiver of a failed lookup.

Fix: `if (!is_smi(size) || Smi::value(size) < 0 || Smi::value(size) > array->length())`
encode it as a plain instance.

## 5. Byte content of copy-on-write arrays and slices recurses without bound

`src/objects.cc`, `Object::byte_content` (around line 46), and
`src/objects_runtime.cc`, `Object::mutable_byte_content`: a
`ByteArrayCow_` recurses into its backing and a byte-array or string
slice into the wrapped object, without a depth limit. A COW array or
slice whose backing is itself (or a cycle of them) overflows the C stack
and crashes the VM. Reached by every blob-taking primitive allowed for
untrusted programs (`blob_equals`, `byte_array_replace`, string and
encoding primitives).

Fix: accept only a byte array or string as the backing of a COW array
and only a byte array, string or COW array (one level) as the wrapped
object of a slice, or bound the recursion depth (2 suffices for compiler
output).

## The object encoder recurses without bound (vm/verifier-link fuzz)

Found by the launch-filter fuzz run (verified/core/fuzz, seed 9): a
verified mutant of tests/exception-test.toit crashed the ASan VM with a
native stack overflow in `EncodeVisitor::visit_array`
(src/encoder.cc). The encoder tracks `level_` but never limits it, so a
cyclic (or very deep) array or list passed to `encode_error` or
`encode_object` recurses until the thread's stack overflows and the
whole VM dies. Not a verifier or core bug (the C++ primitives are the
primitive contract's side), and it is in the format-1 VM too: trusted
or untrusted, format 1 or 2, `verified/core/fuzz/findings/
encoder-cyclic-array.toit` segfaults `toit run` (reproducer snapshot:
encoder-cyclic-array-stack-overflow.snapshot). Fix: bound the nesting
depth: https://github.com/toitlang/toit/pull/3374 (also fixes an
over-read in `core.encode_object` when its 1 KB buffer overflows).

## The hardened hash-find intrinsic bails out at every free slot (trace comparison)

Found 2026-11-11 by `compare_trace.toit` on `tests/trace/maps.toit`.
The interpreter hardening (6e7c3559, upstream draft #3365) checked an
index entry with `hap == null || !is_smi(hap)` in `Interpreter::hash_find`
(`src/interpreter_run.cc`). The smi 0 that marks a free index slot is
the null pointer, so every probe that reached a free slot (every
insertion, every miss) took the `kBail` path and ran the Toit fallback
of `find-body_`. Results were unchanged, only slower: `maps.toit` ran
447k bytecodes instead of 230k. Fixed on `fixes/trace-and-debug`
(checks the `fast_at` result instead) and ported to #3365. Not on master.

## Observations (not bugs today)

* `Object::mutable_byte_content` (`src/objects_runtime.cc`) makes an
  immutable `CowByteArray_` mutable by storing a new backing into the
  instance. If such an instance ever lived in the program heap, this
  would write the read-only program heap. The compiler does not put COW
  instances in the program heap (checked on the dumps of the 414 test programs that compile); the program-heap write guard of Phase 1 should cover the path.
* The debug VM's `-Xtrace` output does not say which process a line
  belongs to, and preemption switches processes without a marker line.
  `verified/tools/compare_trace.toit` works around it by forcing a single
  scheduler thread (`get_nprocs` preloaded to 1) and resynchronizing on the
  reference interpreter's trace. A process id in the trace line would
  make the comparison exact.
