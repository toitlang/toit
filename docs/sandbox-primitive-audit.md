# Audit of the C++ primitives of the untrusted set

When audited, the untrusted policy (`src/primitive_policy.cc`,
docs/sandbox-policy.md) allowed 152 core primitives, `bitmap.blit` and
`bitmap.byte_zap`, and the timer and events modules. 106 of the core
primitives run as proven Rust ports for untrusted (format-2) programs
(verified/core/src/prims). This audit covers the rest: 46 core and 2 bitmap
primitives (then the 48 of verified/core/TRUSTED.md section 8) and the 7
timer and events primitives, all C++. 11 of the 46 core primitives have
since been dropped from the untrusted set (marked *dropped* below; see "A
smaller untrusted set"), leaving 141 core primitives, 35 of them C++. The proofs assume each of them satisfies the primitive contract
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
| `task_new` | An `Instance` of any class supplies the code. The allocator supplies a fresh Task and Stack or reports failure. | The allocator rejects exhausted task IDs before allocating. The final issued ID fits both a tagged integer and the profiler's `int`. A non-lambda fails later at the Toit method check. | ESBMC on 32-bit and 64-bit targets (`task-new`, `task-id-exhaustion`, `task-stack-init`), untrusted suite, tests/sandbox |
| `task_transfer` | Machine-owned Task fields, a saved running stack and the program's task entry. | First transfer installs two frames, preserves the original code slot and saves the caller bci. Frame construction rejects a missing method, absent caller frame, displaced top or insufficient room before writing the target. The caller relies on program admission and stack invariants to exclude those fatal cases. | ESBMC (`task-start`, `task-transfer`), untrusted suite |
| `task_has_messages` | none | OK | fuzz |
| `task_receive_message` | none; decodes a VM-produced message | OK (no message: null since #3372). Allocation failure: the decoder's external finalizers are removed and the call is retried | fuzz |
| `process_send` | the pid, the type (gated), and the message: lists, slices, maps (size, backing, bounds), byte arrays (external ones are transferred and neutered), strings | **fixed**: a shared object is encoded once per reference, so 6 nested lists of 100 references are 10^12 elements; the size pass ran for days (now stops at 2 GB, and at the sender's message-size quota). The size was returned as `unsigned`: a >4 GB encoding got a truncated buffer, overflowed by the second pass (also `spawn`, programs registry). Sandboxed senders could send strings that aren't valid UTF-8 to receivers that rely on valid ones (now refused). Field bounds were fixed in #3373 | message-encoding-size-test, sandbox/message-shared-graph-test, sandbox/invalid-utf-8-literal-test, fuzz (to a pid that never exists) |
| `add_finalizer` | an instance (not one with byte content) or a map; any object as finalizer | OK, with a note: one malloced node (about 40 bytes) per live object with a finalizer, not charged (bounded by the heap quota times about 2). A non-lambda finalizer throws in the process's own finalization task | fuzz, finalizer-churn-test |
| `remove_finalizer` | any heap object | **fixed** (2 bugs): it cleared the finalizer bit of any object, including the VM finalizer that frees an external byte array's memory (a leak); and it left the node on the list until the next GC: add/remove in a loop without allocating grew the malloced list without bound (5M iterations: 200 MB), and when the object got a new finalizer before the GC, the old nodes stayed as long as the object lived | remove-finalizer-external-test, finalizer-churn-test |
| `main_arguments`, `spawn_arguments` | none; decode the buffer the (trusted) launcher encoded, once | OK | fuzz |
| `spawn_method` | none | OK | fuzz |
| `encode_object` (*dropped*), `encode_error` | any objects; `EncodeVisitor` reads list size and backing, strings, byte arrays (proxies have length 0), the stack's frames (format 2: machine records) | **fixed**: for a string of continuation bytes longer than 255 bytes the visitor walked backwards past the string's start. List bounds and nesting were fixed in #3373/#3374; the 1 KB / 16 KB buffers bound output and work | sandbox/invalid-utf-8-literal-test, fuzz |

## Time, randomness, information

| Primitive | Reads / trusts | Verdict | Test |
|---|---|---|---|
| `time` | a bool | OK (microsecond clocks: a timing channel, see the threat table) | fuzz |
| `time_info` | an int64 timestamp, a bool | **fixed**: `gmtime_r`/`localtime_r` fail for years beyond an int (and on Windows for every time before 1970); the fields of the struct were then returned uninitialized (stack contents). UTC fields are now computed without the C library; local times that the C library rejects use the zone offset of an equivalent year; years outside ±2^30 throw `OUT_OF_RANGE`. **Fixed** (red-team round 4): the UTC computation had a signed overflow (`timestamp - days * 86400`) for the timestamps of the last partial day above INT64_MIN (undefined behaviour; release builds wrapped, then threw `OUT_OF_RANGE`). Now **proved** with VeriFast (verified/cxx/annotated/prims/time_info: no overflow or lossy conversion for any int64 on 64- and 32-bit, every stored field a smi; assumed: `localtime_r` returns its fields in range) | time-info-range-test, time-info-before-1970-test |
| `seconds_since_epoch_local` | six int32 and a bool-or-null | OK. The year offset wraps without signed overflow. Linux uses the normalized weekday to distinguish timestamp -1 from failure. The timezone conversion is supplied by libc | [C++ body proof](../verified/cxx/annotated/prims/local_epoch.render), timezone tests, fuzz |
| `get_real_time_clock` | none | OK | fuzz |
| `random`, `random_seed` (*dropped*) | a blob (seed) | OK: per-process PRNG, linear in the seed | fuzz |
| `gc_count`, `bytes_allocated_delta` (*dropped*) | none; own heap counters | OK | fuzz |
| `process_current_id`, `process_system_id` | none | OK (pids are observable by design) | fuzz |
| `word_size`, `platform`, `architecture`, `vm_sdk_version`, `vm_sdk_model`, `app_sdk_version`, `app_sdk_info` (the four SDK queries *dropped*) | none; constants or new strings | OK (they disclose the VM version: by design) | fuzz |
| `literal_index` (*dropped*) | any object; linear scan of the program's literals | OK | fuzz |
| `get_generic_resource_group` (*dropped*) | none; mallocs a group freed only at process exit | **fixed**: not charged; a loop took 64 bytes of VM memory per call beyond any quota. Now at most 64 resource groups per sandboxed process (QUOTA_EXCEEDED); charging them as external memory broke tight heaps (max-heap-size-test) | sandbox/resource-group-churn-test |

## Byte arrays, strings, numbers

| Primitive | Reads / trusts | Verdict | Test |
|---|---|---|---|
| `byte_array_new_external` (*dropped*) | a length (negative refused, charged) | OK (cleared) | fuzz |
| `create_off_heap_byte_array` (*dropped*) | a length (negative refused, charged) | **fixed**: the malloced memory was not cleared; 99% of the bytes of a new array held what other processes and the VM had freed (cross-container disclosure). TRUSTED.md section 8 claimed "zeroed" | off-heap-byte-array-cleared-test |
| `byte_array_convert_to_string`, `byte_array_is_valid_string_content` | a blob (string, byte array, slice, COW; external raw only) and a range, checked | OK | fuzz |
| `int_parse` | a checked blob slice of 1–18 bytes, exact signed decimal result or marked error | OK | fuzz and [C++ body proof](../verified/cxx/annotated/prims/int_parse.render) |
| `float_parse` | checked blob range, NUL-terminated input, full consumption by `strtod` | OK under the string, libc and allocator contracts. Embedded NULs are rejected. | [C++ body proof](../verified/cxx/annotated/prims/float_parse.render), numeric regressions, fuzz with 1 MB digit strings |
| `float_to_string` | a double, precision 0..64 or null; fixed-precision path retries once with a bounded allocation | primitive body and both buffer writers proved. Decimal conversion relies on libc and Dragonbox. The shortest writer checks the returned components before indexing | number-test, fuzz |
| `float_round` | a double and precision 0..15, exact positive decimal scale, double result or marked error | OK under the double accessor, floating-point and allocator contracts | [C++ body proof](../verified/cxx/annotated/prims/float_round.render) and numeric regressions |
| `int64_to_string`, `uint64_to_string`, `printf_style_int64_to_string`, `smi_to_string_base_10` | an integer and checked radix, up to 64 digits and a sign passed to the allocator with their length | OK | fuzz and [C++ body proofs](../verified/cxx/annotated/prims/format_integer.render) |
| `string_to_utf_16` | a string or string slice | **fixed**: `Utils::utf_8_to_16` read as many continuation bytes as the first byte announces (up to 7 for 0xff) past the end of a string that isn't valid UTF-8, and returned what it read. Invalid strings: crafted snapshot literals, crafted slices, and (fixed too) TISON | sandbox/invalid-utf-8-literal-test, utf-16-test (ctest), tison-invalid-utf-8-test |
| `utf_16_to_string` | a blob of even length below 1 GB; two passes of the same conversion | OK | fuzz |
| `crc` | a blob and range (checked), a width (checked), a table: a byte blob of 256 or a list whose backing array has 256 entries (the list's size field is not used) | OK | fuzz |

## bitmap, timer, events

| Primitive | Reads / trusts | Verdict | Test |
|---|---|---|---|
| `bitmap.byte_zap` | a mutable blob (program-heap objects refused), a value | OK | fuzz, sandbox/bitmap-draw-text-test |
| `bitmap.blit` | a mutable and a constant blob, strides and pixels per line limited to 23 bits (pixel strides to 7 bits), a lookup table of at least 256 bytes. VeriFast checks the primitive entry, copy-on-write decoding, sequential borrowing of possibly overlapping views, every row and pixel index, reverse strides, the extra byte of a 16-bit write and the exact work limit. ESBMC checks the six native pixel operations with overlapping views | **fixed** (denial of service): with zero pixel strides the pixels per line (up to 2^23) aren't bounded by the blob sizes, and with a zero line stride on one side the lines are bounded by the other side only; a 1-byte source and a 100 KB destination took hours in one call. Either an uninterrupted-run quota or a total CPU quota bounds the work to four passes over both blobs plus 65,536 pixels. The budget uses 64-bit arithmetic on both word sizes. Saturating byte addition now widens before clamping even when a wide mask is used | sandbox/blit-unbounded-work-test, sandbox/blit-cpu-budget-test |
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

## A smaller untrusted set (applied, see the end of this section)

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

### Applied (2026-11-11)

Checked on a broader set: the 282 programs the untrusted suite runs
(verified/tools/untrusted_suite.toit) and the 98 sandbox tests (whose
images include the trusted driver), each compiled to a snapshot and listed
with `toit.run --verify --primitives` (script and lists in
/home/flo/work/opentoit-sandbox-artifacts/policy-smaller-primitive-set).
"Suite" and "sandbox" count the programs that reference the primitive
after tree shaking.

| Primitive | Suite | Sandbox | Library entry points | Verdict |
|---|---|---|---|---|
| `get_generic_resource_group` | 0 | 8 | `resource-freeing-module_`: crypto (sha, adler32, siphash), zlib, flash regions (storage), rmt, pulse counter, esp32 (the 8: trusted tool drivers, module-crypto, resource-group-churn) | drop: every user is a denied module, whose library calls now throw `PERMISSION_DENIED` instead of `PRIMITIVE_LOOKUP_FAILED` |
| `create_off_heap_byte_array` | 0 | 6 | `create-off-heap-byte-array` (the 6: trusted tool drivers, through the host package) | drop |
| `byte_array_new_external` | 1 | 0 | `ByteArray.external`; `bytes.Buffer` for backing stores above 128 bytes (bytes-deprecated-test references it, never above 128 bytes); TLS (denied) | drop; `bytes.Buffer` falls back to an ordinary byte array on `PERMISSION_DENIED`. `ByteArray n` doesn't use it: large arrays get their external backing store inside `byte_array_new` (sandbox/cli/large-byte-array) |
| `encode_object` | 0 | 0 | `encode_` (core, no callers) | drop |
| `literal_index` | 0 | 0 | `literal-index_` (core, no callers) | drop |
| `bytes_allocated_delta` | 0 | 0 | `system.bytes-allocated-delta` (deprecated) | drop (heap statistics, as `process_stats`) |
| `random_seed` | 0 | 0 | `set-random-seed` (tests/random-test, not in the suite) | drop |
| `vm_sdk_version`, `vm_sdk_model`, `app_sdk_version`, `app_sdk_info` | 0 | 0 | `system.vm-sdk-version` etc. and their deprecated core aliases | drop (as `vm_sdk_info`) |
| `gc_count` | 1 | 0 | `system.gc-count`, deprecated `gc-count` | keep: finalizer-test waits for a GC with it to see finalizers run; with `gc_count` denied it fails untrusted (tried) |
| `platform` | 3 | 6 | `system.platform`, `system.LINE-TERMINATOR`; ble, dns (denied) | keep: platform-test, regress/issue2856-test and set-map-remove-first-test size their work by platform |
| `architecture` | 1 | 0 | `system.architecture`; spi, rmt, touch (denied) | keep: platform-test |
| `word_size` | 0 | 1 | `system.BYTES-PER-WORD`, `system.BITS-PER-WORD` and the deprecated core aliases | keep: bitness checks are ordinary, and the smi range tells the word size anyway, so denying it hides nothing |
| `crc`, `string_to_utf_16`, `utf_16_to_string`, `seconds_since_epoch_local` | 0 | 0-1 | `crc`, `string.to-utf-16`, `Time.local` | keep (ordinary APIs, as above) |
| `byte_array_is_valid_string_content`, `main_arguments` | 5, 2 | 6, 97 | `ByteArray.to-string-non-throwing`, `main args` | keep |

Dropped: 11 (the untrusted set is now 141 core primitives, 106 Rust and
35 C++, plus the 2 bitmap and the 7 timer and events primitives). The
untrusted suite still reports 280 identical and the same two known
differences. Denial tests: tests/sandbox/core-external-byte-array,
core-get-generic-resource-group, core-encode-object, core-literal-index,
core-bytes-allocated-delta, core-random-seed and core-sdk-version.

Cheap to move to Rust (pure, need only blobs, integers and the existing
string and byte-array allocation of `prims`): `byte_array_convert_to_string`
and `byte_array_is_valid_string_content` (UTF-8 validation), `int_parse`,
the four integer formatters (`smi_to_string_base_10`, `int64_to_string`,
`uint64_to_string`, `printf_style_int64_to_string`), `string_to_utf_16`,
`utf_16_to_string`, `crc`, `float_round` (with `round` and the binary64 operations as trusted
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
only throw permission errors.

### Fuzz runs (2026-11-11, ASan host build, logs in /home/flo/work/opentoit-sandbox-artifacts/assurance/fuzz)

| Batch | Build | Mode | Seeds x time | Calls | Result |
|---|---|---|---|---|---|
| b1 | before the fixes | both | 6 x 2 min | - | every trusted run stopped on the `string_rune_count` ASan report; every untrusted run died of a lambda finalizer taking an argument (driver bug) |
| b2 | ASan fix | trusted | 6 x 25 min (2.5 CPU-h) | 47.7M | clean |
| b2 | ASan fix | untrusted | 6 x 2-3 min | 5.0M | every run ran out of its 64 MB heap: the `remove_finalizer` leak of external byte arrays (fixed) |
| b3 | all fixes | trusted | 8 x 29 min (3.9 CPU-h) | 30.3M | clean; 2 `slow:` (base64 of 1 MB under ASan, 1.3 s; denied for untrusted programs) |
| b3 | all fixes | untrusted | 8 x 29 min (3.9 CPU-h) | 68.2M | clean; one transient out-of-memory in one run, which went on |
