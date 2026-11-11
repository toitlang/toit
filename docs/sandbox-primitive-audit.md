# Audit of the C++ primitives of the untrusted set

The untrusted policy (`src/primitive_policy.cc`, docs/sandbox-policy.md)
allows 152 core primitives, `bitmap.blit` and `bitmap.byte_zap`, and the
timer and events modules. 106 of the core primitives run as proven Rust
ports for untrusted (format-2) programs (verified/core/src/prims). This
audit covers the rest: 46 core and 2 bitmap primitives (the 48 of
verified/core/TRUSTED.md section 8) and the 7 timer and events primitives,
all C++. The proofs assume each of them satisfies the primitive contract
(`prim_heap_ok`: the heap stays well formed, only new objects are added,
machine-owned objects are untouched, the result is a value) and say nothing
about isolation or denial of service, so the audit looks at both.

Method (2026-11-11): reading each primitive with its argument macros
(`ARGS`, `Blob`, `MutableBlob`, `MAKE_UNPACKING_MACRO`) and the C++ it calls
(encoders, decoders, resource groups, finalizer lists, UTF-8 conversions),
with hostile arguments in mind: wrong types, program-heap (read-only)
objects, external and proxy byte arrays, collections whose size and backing
fields a program can set to anything (`List_`, `ListSlice_`, `Map_`, slices,
copy-on-write arrays), strings that aren't valid UTF-8 (string literals of a
crafted snapshot are not checked, and a `StringSlice_` with crafted bounds
can be concatenated into one), extreme integers, re-entrancy and GC points,
uncharged allocations, and the time a call can take: a primitive is not
preemptible, and the run-time quota kills a process only when its primitive
returns, so an unbounded primitive keeps a scheduler thread and makes the
container unkillable. Then fuzzing with tests/fuzz/primitive-fuzz.toit,
extended with these shapes, on an ASan build, trusted and untrusted (see
"Fuzzing" below).

Verdicts: **OK** (no issue found), **fixed** (a bug, fixed on
`assurance/primitives-and-gate` with a regression test), **finding** (an
issue left open, see the notes).

## Task and message primitives

| Primitive | Reads from its arguments / trusts | Verdict | Test |
|---|---|---|---|
| `task_new` | an `Instance` (any class) stored as the new task's code; allocates a Task and a Stack (no GC: fails and is retried) | OK. A non-lambda fails later in Toit (the lambda call checks the method id). Not fuzzed (creates tasks running arbitrary code) | untrusted suite, tests/sandbox |
| `task_transfer` | a Task with a stack; format 2: `v2_task_transfer` builds the entry frames of a new task | OK. `FATAL("cannot start task")` is reachable only with a malformed stack (no caller frame, or a new task's stack moved), which an accepted program can't produce: Task fields are machine-owned (SOUNDNESS.md, proven) | untrusted suite |
| `task_has_messages` | none | OK | fuzz |
| `task_receive_message` | none; decodes a VM-produced message | OK (no message: null since #3372). Allocation failure: the decoder's external finalizers are removed and the call is retried | fuzz |
| `process_send` | the pid, the type (gated), and the message: lists, slices, maps (size, backing, bounds), byte arrays (external ones are transferred and neutered), strings | **fixed**: a shared object is encoded once per reference, so 6 nested lists of 100 references are 10^12 elements; the size pass ran for days (now stops at 2 GB, and at the sender's message-size quota). The size was returned as `unsigned`: a >4 GB encoding got a truncated buffer, overflowed by the second pass (also `spawn`, programs registry). Sandboxed senders could send strings that aren't valid UTF-8 to receivers that rely on valid ones (now refused). Field bounds were fixed in #3373 | message-encoding-size-test, sandbox/message-shared-graph-test, sandbox/invalid-utf-8-literal-test, fuzz (to a pid that never exists) |
| `add_finalizer` | an instance (not one with byte content) or a map; any object as finalizer | OK, with a note: one malloced node (about 40 bytes) per live object with a finalizer, not charged (bounded by the heap quota times about 2). A non-lambda finalizer throws in the process's own finalization task | fuzz, finalizer-churn-test |
| `remove_finalizer` | any heap object | **fixed** (2 bugs): it cleared the finalizer bit of any object, including the VM finalizer that frees an external byte array's memory (a leak); and it left the node on the list until the next GC: add/remove in a loop without allocating grew the malloced list without bound (5M iterations: 200 MB), and when the object got a new finalizer before the GC, the old nodes stayed as long as the object lived | remove-finalizer-external-test, finalizer-churn-test |
| `main_arguments`, `spawn_arguments` | none; decode the buffer the (trusted) launcher encoded, once | OK | fuzz |
| `spawn_method` | none | OK | fuzz |
| `encode_object`, `encode_error` | any objects; `EncodeVisitor` reads list size and backing, strings, byte arrays (proxies have length 0), the stack's frames (format 2: machine records) | **fixed**: for a string of continuation bytes longer than 255 bytes the visitor walked backwards past the string's start. List bounds and nesting were fixed in #3373/#3374; the 1 KB / 16 KB buffers bound output and work | sandbox/invalid-utf-8-literal-test, fuzz |

## Time, randomness, information

| Primitive | Reads / trusts | Verdict | Test |
|---|---|---|---|
| `time` | a bool | OK (microsecond clocks: a timing channel, see the threat table) | fuzz |
| `time_info` | an int64 timestamp, a bool | **fixed**: `gmtime_r`/`localtime_r` fail for years beyond an int; the fields of the struct were then returned uninitialized (stack contents) | time-info-range-test |
| `seconds_since_epoch_local` | six int32 and a bool-or-null | OK, with a note: `year - 1900` overflows for years near INT32_MIN (signed overflow, benign); `mktime` reads the global time zone, which only privileged code sets | fuzz |
| `get_real_time_clock` | none | OK | fuzz |
| `random`, `random_seed` | a blob (seed) | OK: per-process PRNG, linear in the seed | fuzz |
| `gc_count`, `bytes_allocated_delta` | none; own heap counters | OK | fuzz |
| `process_current_id`, `process_system_id` | none | OK (pids are observable by design) | fuzz |
| `word_size`, `platform`, `architecture`, `vm_sdk_version`, `vm_sdk_model`, `app_sdk_version`, `app_sdk_info` | none; constants or new strings | OK (they disclose the VM version: by design) | fuzz |
| `literal_index` | any object; linear scan of the program's literals | OK | fuzz |
| `get_generic_resource_group` | none; mallocs a group freed only at process exit | **fixed**: not charged; a loop took 64 bytes of VM memory per call beyond any quota. Now at most 64 resource groups per sandboxed process (QUOTA_EXCEEDED); charging them as external memory broke tight heaps (max-heap-size-test) | sandbox/resource-group-churn-test |

## Byte arrays, strings, numbers

| Primitive | Reads / trusts | Verdict | Test |
|---|---|---|---|
| `byte_array_new_external` | a length (negative refused, charged) | OK (cleared) | fuzz |
| `create_off_heap_byte_array` | a length (negative refused, charged) | **fixed**: the malloced memory was not cleared; 99% of the bytes of a new array held what other processes and the VM had freed (cross-container disclosure). TRUSTED.md section 8 claimed "zeroed" | off-heap-byte-array-cleared-test |
| `byte_array_convert_to_string`, `byte_array_is_valid_string_content` | a blob (string, byte array, slice, COW; external raw only) and a range, checked | OK | fuzz |
| `int_parse` | a blob and range (checked), at most 18 characters | OK | fuzz |
| `float_parse` | a blob and range (checked); `strtod` on a NUL-terminated copy (or on a whole string, which is NUL-terminated) | OK. An embedded NUL ends the parse early (semantic, not safety) | fuzz (with 1 MB digit strings) |
| `float_to_string` | a double, precision 0..64 or null; buffer grown as needed | OK | fuzz |
| `float_round` | a double, precision 0..15 | OK (large negative values aren't rounded: semantic) | fuzz |
| `int64_to_string`, `uint64_to_string`, `printf_style_int64_to_string`, `smi_to_string_base_10` | an integer, a base (checked); 70- and 32-byte buffers (64 binary digits, sign and NUL fit) | OK | fuzz |
| `string_to_utf_16` | a string or string slice | **fixed**: `Utils::utf_8_to_16` read as many continuation bytes as the first byte announces (up to 7 for 0xff) past the end of a string that isn't valid UTF-8, and returned what it read. Invalid strings: crafted snapshot literals, crafted slices, and (fixed too) TISON | sandbox/invalid-utf-8-literal-test, utf-16-test (ctest), tison-invalid-utf-8-test |
| `utf_16_to_string` | a blob of even length below 1 GB; two passes of the same conversion | OK | fuzz |
| `crc` | a blob and range (checked), a width (checked), a table: a byte blob of 256 or a list whose backing array has 256 entries (the list's size field is not used) | OK | fuzz |

## bitmap, timer, events

| Primitive | Reads / trusts | Verdict | Test |
|---|---|---|---|
| `bitmap.byte_zap` | a mutable blob (program-heap objects refused), a value | OK | fuzz, sandbox/bitmap-draw-text-test |
| `bitmap.blit` | a mutable and a constant blob, strides and pixels per line limited to 23 bits (pixel strides to 7 bits), a lookup table of at least 256 bytes. Index arithmetic: the loop condition bounds every source and destination index (reviewed for negative destination pixel strides and zero pixels per line) | **fixed** (denial of service): with zero pixel strides the pixels per line (up to 2^23) aren't bounded by the blob sizes, and with a zero line stride on one side the lines are bounded by the other side only; a 1-byte source and a 100 KB destination took hours in one call. For processes with a run-time quota the work is now bounded by four passes over both blobs | sandbox/blit-unbounded-work-test |
| `timer.init` | none; mallocs a group freed at process exit | **fixed**: unbounded (as `get_generic_resource_group`) | sandbox/resource-group-churn-test |
| `timer.create` | a timer group (tag-checked proxy) | OK: the timer quota is checked before the malloc | sandbox/quota-timers-test |
| `timer.arm` | a timer, an int64 deadline | OK (extreme deadlines: #3364) | fuzz |
| `timer.delete` | a group and a timer (the timer may belong to another group of the same process: the unlink doesn't depend on the list) | OK; a second delete fails (ALREADY_CLOSED) | fuzz |
| `events.read_state`, `register_monitor_notifier`, `unregister_monitor_notifier` | a group and a resource (the resource must belong to the group, #3362), any monitor object (a GC root) | OK: one notifier per resource, replaced on update | fuzz |

Proxies (resource groups, timers) can't be forged: their address is set
only by primitives, and the message encoder refuses byte arrays whose
external memory isn't raw bytes, so they don't cross processes.

## Also found (not in the 48)

- `string_rune_count` and `blob_index_of` (C++, ported to Rust for
  untrusted programs) read the aligned words around a blob. That can't
  fault, but ASan reports it for external byte arrays, which stopped every
  ASan fuzz run within minutes; sanitizer builds now use byte loops
  (`__SANITIZE_ADDRESS__`, as only `TOIT_ASAN` was checked).
- `tison.decode` (the encoding module, denied for untrusted programs)
  created strings that aren't valid UTF-8 from untrusted input: fixed with
  the UTF-8 conversions above.
- `tison.encode` had the 32-bit size truncation of the message encoder: a
  list of 100 references to a 50 MB string overflowed the result's buffer
  (fixed with process_send).

## A smaller untrusted set (proposal, not applied)

Measured 2026-11-11: the primitives four programs reference after tree
shaking (`toit.run --verify --primitives` on their snapshots; programs and
lists in /home/flo/work/opentoit-sandbox-artifacts/assurance/primitive-sets):
an empty `main:`, hello world, the heat-pump client of
tests/sandbox/heat-pump-test.toit, and a typical program (JSON, maps, lists,
strings, number formatting and parsing, `Time`, exceptions, tasks,
timeouts). The first three reference the same 102 primitives (the core
library's message loop, printing, exceptions and timers); the typical
program 120.

Of the 48 C++ primitives (plus timer and events):

- Every program: `task_new`, `task_transfer`, `task_has_messages`,
  `task_receive_message`, `process_send`, `process_current_id`,
  `process_system_id`, `add_finalizer`, `remove_finalizer`, `encode_error`,
  `spawn_arguments`, `spawn_method`, `time`, `random`,
  `byte_array_convert_to_string`, `float_to_string`, `int64_to_string`,
  `smi_to_string_base_10`, `bitmap.blit`, `bitmap.byte_zap`, `timer.*`,
  `events.register_monitor_notifier`.
- The typical program also: `float_parse`, `float_round`, `int_parse`,
  `printf_style_int64_to_string`, `uint64_to_string`,
  `get_real_time_clock`, `time_info`. `main_arguments` is used by every
  program whose `main` takes arguments.
- None of the four (21): `app_sdk_info`, `app_sdk_version`, `architecture`,
  `byte_array_is_valid_string_content`, `byte_array_new_external`,
  `bytes_allocated_delta`, `crc`, `create_off_heap_byte_array`,
  `encode_object`, `gc_count`, `get_generic_resource_group`,
  `literal_index`, `main_arguments`, `platform`, `random_seed`,
  `seconds_since_epoch_local`, `string_to_utf_16`, `utf_16_to_string`,
  `vm_sdk_model`, `vm_sdk_version`, `word_size`.

Proposal: drop from the untrusted set, at no cost to ordinary programs,

- `get_generic_resource_group`: only used by modules the policy denies
  (zlib, crypto, rmt, esp32, pulse counter);
- `create_off_heap_byte_array` and `byte_array_new_external`: external
  byte arrays are an optimization for transfers (`ByteArray.external`;
  large arrays are external anyway); the first had the disclosure bug;
- `encode_object`, `literal_index`, `gc_count`, `bytes_allocated_delta`:
  diagnostics and serialization helpers of the system and debug libraries;
- `random_seed`: only for reproducible tests; seeding is per process, but
  nothing needs it;
- `app_sdk_info`, `vm_sdk_model` (and possibly `vm_sdk_version`,
  `app_sdk_version`, `platform`, `architecture`, `word_size`): they only
  serve `system.*` queries and fingerprint the VM.

That removes 10 to 15 of the 48. Keep `crc`, `string_to_utf_16`,
`utf_16_to_string`, `byte_array_is_valid_string_content`,
`seconds_since_epoch_local` and `main_arguments`: unused by these programs
but behind ordinary APIs (`crc`, `string.to-utf-16`,
`ByteArray.to-string-non-throwing`, `Time.local`, `main args`).

Cheap to move to Rust (pure, need only blobs, integers and the existing
string and byte-array allocation of `prims`): `byte_array_convert_to_string`
and `byte_array_is_valid_string_content` (UTF-8 validation), `int_parse`,
the four integer formatters (`smi_to_string_base_10`, `int64_to_string`,
`uint64_to_string`, `printf_style_int64_to_string`), `string_to_utf_16`,
`utf_16_to_string`, `crc`, `float_round` (with `pow`/`round` as trusted
scalars, like prims/fp.rs), `word_size`, and `bitmap.blit`/`byte_zap`
(bounded loops over two blobs; `blit` is in every program and had the
unbounded-work bug). Moderate: `literal_index` and `spawn_method` (program
tables), `random` (per-process PRNG state behind the FFI). Expensive:
`float_to_string` (shortest round-trip printing) and `float_parse`
(correctly rounded parsing), `encode_error`/`encode_object` (the encoder).
The rest stays in C++ by nature: tasks, messages, finalizers, clocks,
argument decoding, external memory, timers and events.

## Fuzzing

tests/fuzz/primitive-fuzz.toit now adds adversarial shapes to its argument
pool: lists whose size is beyond, negative or not a smi, lists with
non-array or self backings, out-of-range list slices, maps and sets with
inconsistent size, backing and index fields, self-referential maps, lists
and arrays, 200-deep nesting, 50-deep byte-array slice chains,
copy-on-write arrays claiming a program-heap backing is mutable, string
byte slices cutting UTF-8 sequences or out of range, program-heap literals,
1 MB blobs and strings, external byte arrays and tasks. It also fuzzes
`process_send` (to a pid that never exists, so only the encoder runs) and,
in an untrusted container (`toit run --untrusted`), skips primitives that
only throw permission errors. Results: see "Fuzz runs".
