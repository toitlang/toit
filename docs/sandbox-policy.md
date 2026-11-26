# Sandbox policy

Every process group (container) in the VM runs with a `PrimitivePolicy`
(`src/primitive_policy.h`). The policy decides which primitives the group
can call, which quotas apply to it, and whether its messaging is
restricted. It is immutable, owned by the `ProcessGroup`, and cached by
every `Process` of the group. Processes spawned from inside a group are
in the same group, so they inherit the policy.

There are three kinds of policies:

| Kind | Value | Used for | Primitives | Quotas | Messaging |
|---|---|---|---|---|---|
| system | 0 | the boot process | all, including `PRIVILEGED` ones | none | unrestricted |
| trusted | 1 | regular containers (default) | all except `PRIVILEGED` ones | none by default | unrestricted |
| untrusted | 2 | sandboxed containers | the allowed set below | the defaults below | restricted |

`Process::is_privileged()` is a policy query (`policy()->is_system()`);
the old per-process privilege bit is gone. Only the system process gets the
system policy. Launching programs (`snapshot.launch`), starting and
killing flash containers (`programs_registry.spawn`, `kill`,
`next_group_id`) and issuing messaging grants (`core.process_grant_send`)
are `PRIVILEGED`.

## Primitive gating

The `PRIMITIVE` bytecode looks up the primitive in the tables of the
process' policy (`PrimitivePolicy::at`), with bounds checks on both the
module and the index. For the untrusted policy:

- Modules that are denied as a whole have no table. Calling one of their
  primitives takes the existing lookup-failure path and throws
  `PRIMITIVE_LOOKUP_FAILED` in Toit.
- Modules that are partially allowed (core, bitmap) have a policy-owned
  table. Denied entries keep the arity of the real primitive (so the
  interpreter finds the arguments) and fail with `PERMISSION_DENIED`.

For format-2 programs (since 2026-11-26) the same decision is made from the
policy's verifier table (`PrimitivePolicy::verifier_arities`: the arity of
every allowed primitive, `VERIFIER_DENIED` for the denied entries of core
and bitmap, `VERIFIER_ABSENT` for the modules denied as a whole), and it is
part of the proof:

- the install-time verifier checks every `PRIMITIVE` against that table
  (allowed with the method's arity, denied or absent; any other primitive
  or arity is rejected), and the certificate's header names the table it
  was made for (another policy's certificate is rejected up front);
- the verified core gets the same table and runs a primitive (its Rust
  port or the C++ entry) only where the table allows it; a denied one
  fails with `PERMISSION_DENIED` and an absent one throws
  `PRIMITIVE_LOOKUP_FAILED` without any call, as before. Verus proves that
  no other primitive runs (docs/sandbox-guarantee.md, clause 6);
- a verdict is used only for a process of the policy it was computed for
  (`V2MethodTable::runs_verified`), and the verification epoch hashes the
  policy tables (src/primitive_policy.*), so a firmware with another
  allowed set does not take old verdicts.

Programs do contain calls of denied primitives (the core library's `print`
tries `write_on_stdout` first), so they are accepted and completed with the
denial, not rejected: what is proven is that only allowed primitives run,
not that an accepted program contains no call of a denied one. A denied or
absent primitive is accepted with any arity (the core reads none of its
arguments); an index past the VM's primitive table names no primitive and
is rejected at install. Until 2026-11-26 the install-time check compared
arities with the full table, which rejected some crafted denied calls by
their arity (red-team batteries prim-denied, prim-spawn); they are now
accepted, and the batteries check at run time that the program sees
PERMISSION_DENIED and that nothing ran (review/red-team/round4/ATTEMPTS.txt).

### Allowed set (untrusted)

- core, measured set (what the core library needs): `add_finalizer`,
  `array_at`, `array_at_put`, `array_expand`, `array_length`, `array_new`,
  `array_replace`, `blob_equals`, `blob_hash_code`, `blob_index_of`,
  `byte_array_at`, `byte_array_at_put`, `byte_array_convert_to_string`,
  `byte_array_is_raw_bytes`, `byte_array_length`, `byte_array_new`,
  `byte_array_replace`, `compare_to`, `concat_strings`,
  `count_leading_zeros`, `encode_error`, all `float_*`, `int64_to_string`,
  all `large_integer_*`, `list_add`, `min_special_compare_to`,
  `number_to_float`, `number_to_integer`, `object_class_id`,
  `process_current_id`, `process_send` (gated, see below),
  `process_system_id`, `random`, `rebuild_hash_index`, `remove_finalizer`,
  all `smi_*`, `string_add`, `string_at`, `string_compare`,
  `string_hash_code`, `string_length`, `string_raw_at`, `string_slice`,
  `string_write_to_byte_array`, `string_rune_count`, `task_has_messages`,
  `task_new`, `task_receive_message`, `task_transfer`, `time`,
  `compare_simple_json_string`, `hash_simple_json_string`,
  `json_skip_whitespace`, `size_of_json_number`, `int_parse`,
  `float_parse`, `read_*_endian`, `put_*_endian`.
- core, read-only clock access (`Time.now`, `Time.local`,
  `Time.monotonic-us`): `get_real_time_clock`, `time_info`,
  `seconds_since_epoch_local`.
- core, remaining pure and process-local primitives: `raw_to_float`,
  `raw32_to_float`, `uint64_to_string`, `printf_style_int64_to_string`,
  `popcount`, `int_vector_equals`, `string_from_rune`, `string_to_utf_16`,
  `utf_16_to_string`, `byte_array_is_valid_string_content`, `crc`,
  `word_size`, `platform`, `architecture` (`system.BITS-PER-WORD`,
  `system.platform`, `system.LINE-TERMINATOR`, `system.architecture`:
  portable programs check them), `gc_count` (`system.gc-count`: waiting for
  a GC, for example to see finalizers run), `main_arguments`,
  `spawn_method`, `spawn_arguments`.
- timer: the whole module. events: the whole module.
- bitmap: `blit` and `byte_zap`.

That is 143 primitives of the core and bitmap modules (141 core, 2
bitmap), plus the 7 of timer and events. 106 of the core primitives run as
proven Rust ports for untrusted (format-2) programs (verified/core); the
other 35 core and the 2 bitmap primitives are C++
(docs/sandbox-primitive-audit.md).

Process-local primitives that no ordinary program needs are left out as
well (measured on the untrusted suite, docs/sandbox-primitive-audit.md, "A
smaller untrusted set"); their documented APIs throw `PERMISSION_DENIED`:

- `byte_array_new_external`, `create_off_heap_byte_array`
  (`ByteArray.external`, `create-off-heap-byte-array`): explicit external
  memory. `ByteArray n` works for every `n`: a byte array larger than the
  largest heap allocation (about a heap page) gets an external (malloced, cleared) backing store inside
  `byte_array_new`, charged to the process heap. The deprecated
  `bytes.Buffer`, which uses `ByteArray.external` for backing stores above
  128 bytes, falls back to an ordinary byte array.
- `get_generic_resource_group` (`resource-freeing-module_`): only used by
  modules that are denied anyway (crypto, zlib, flash, rmt, pulse counter,
  esp32); their library calls now fail with `PERMISSION_DENIED` before
  reaching the module's own primitive.
- `encode_object` (the object encoder; `encode_error` stays for uncaught
  exceptions), `literal_index` (debugging tools).
- `bytes_allocated_delta` (`system.bytes-allocated-delta`): heap
  statistics, like `process_stats`.
- `random_seed` (`set-random-seed`): `random` works, reseeding doesn't.
- `vm_sdk_version`, `vm_sdk_model`, `app_sdk_version`, `app_sdk_info`
  (`system.vm-sdk-version` and friends), like `vm_sdk_info`.

Everything else is denied, in particular: `spawn`, `write_on_stdout`,
`write_on_stderr`, `get_env`, `set_env`, `hostname`, `program_name`,
`program_path`, `vm_sdk_info`, `set_tz` and `set_real_time_clock` (the
clock and time zone can be read but not changed), `firmware_*`,
`rtc_user_bytes`, `process_signal_kill`, `process_get_priority`,
`process_set_priority`, `process_stats`, `pid_for_external_id`,
`process_policy`, `process_grant_send`, `add_entropy`, `profiler_*`,
`set_max_heap_size`, `tune_memory_use`, `debug_set_memory_limit`,
`dump_heap`, `serial_print_heap_report`, and all other modules (file,
networking, TLS, crypto, encoding, math, zlib, snapshot, image,
programs_registry, flash, device modules, ...).

`print` in an untrusted container goes through the system process: the
system process provides a print service (tagged `sandbox-only`) that is
only discovered by untrusted clients. `print_`/`debug` write to stdout
directly and therefore throw `PERMISSION_DENIED`. Uncaught exceptions are
reported to the system process with a trace message, as for every
container.

## Messaging and capability grants

An untrusted process may send messages only to:

- the system process (`pid < 0` or its pid),
- processes in its own group,
- pids in its group's allowed-target set.

Sends to any other pid fail with `PERMISSION_DENIED`, whether the pid
exists or not. The message type must be one of `SYSTEM_TRACE` (only to the
system process), `SYSTEM_RPC_REQUEST`, `SYSTEM_RPC_REPLY`,
`SYSTEM_RPC_CANCEL`, `SYSTEM_RPC_NOTIFY_RESOURCE`, or a type
`>= RESERVED-MESSAGE-TYPES_` (64). The encoded size of a message
(including out-of-line byte arrays and strings) is capped.

Grants to the allowed-target set are issued:

- by the system process when it answers service discovery: every provider
  pid returned to an untrusted client is granted to the client's group
  (`system/services.toit`, `SystemServiceManager.discover`, through the
  privileged primitive `core.process_grant_send`);
- by the scheduler when a process of an untrusted group receives an RPC
  request. Admission to the receiver's mailbox grants the requester's pid
  so the provider can reply. A rejected request leaves the grant set unchanged.

The set holds at most `max_send_grants` pids, and grants are never
evicted: evicting an older grant would silently break a capability the
container uses. The system process and processes of the own group don't
take up room. When the set is full, a discovery that would grant a new
provider fails with `QUOTA_EXCEEDED` (the client sees the exception), and
an RPC request from a new requester to a provider in the container is
refused like a request to a full mailbox (`process_send` returns false for
a trusted sender). Pids are never reused, so grants for dead processes are
inert, but they keep their room.

### Serving sandboxed clients is opt-in

Every service provider rejects untrusted clients unless it opts in
(`ServiceProvider.accepts-untrusted-clients`, false by default): opening
a client throws `PERMISSION_DENIED`. The choice is sent with the
registration, and discovery returns a provider outside the system process
to an untrusted client only if it opts in, so the client gets no grant for
a provider that doesn't serve it (and can't send it messages of any type).
Providers in the system process are reachable anyway; discovery returns
them, and opening them fails with `PERMISSION_DENIED` unless they opt in.
Service discovery and the sandbox print service opt in; the container,
storage, network and other system services do not, so an untrusted
container can't start containers, use storage or open sockets. A trusted
container that wants to serve sandboxes overrides
`accepts-untrusted-clients` (the heat-pump driver of `heat-pump-test`).

Before, providers outside the system process accepted untrusted clients
unless they opted out; only system services were opt-in.

### Providing services is a privilege

An untrusted container can't register service providers: the system
process' discovery service refuses `listen` from an untrusted process with
`SERVICE_REGISTRATION_DENIED`. Otherwise a sandbox could offer a service
under the uuid a trusted client expects, and the trusted client would use
it whenever no trusted provider is registered (during boot, or after the
trusted provider crashed).

The launch policy can grant it (default off):

    containers.start image-id arguments --untrusted --may-provide-services

The grant is entry 9 of the policy list (`ContainerService.POLICY-GRANTS-INDEX`,
bit `POLICY-GRANT-PROVIDE-SERVICES`); the VM ignores the entry, and the
system process looks it up by the group id of the registering process.
The providers of such a container live in their own namespace: they are
registered with the lowest priority and the tag `untrusted-provider`
(`TAG-UNTRUSTED-PROVIDER` in `system.services`), whatever the container
asks for, and discovery returns them only to trusted clients that opt in
by allowing the tag explicitly:

    selector := MyService.SELECTOR.restrict.allow --tag=TAG-UNTRUSTED-PROVIDER

Plain selectors (and restricted selectors that don't allow the tag) never
match them, not even when no trusted provider of the service runs; the
client library filters them as well. Untrusted clients never discover
them, so sandboxes can't reach each other through services. Trusted
containers can always provide services.

## Quotas

Quotas are installed by the launcher and can't be changed by the
program. A value of 0 means unlimited. Defaults of the untrusted policy:

| Quota | Host default | Device default | Enforced in |
|---|---|---|---|
| heap per process (`max_heap_bytes`) | 64 MB | 128 KB | `Process` constructor; `set_max_heap_size` is denied, and for trusted policies with a cap it can't raise the cap |
| messages a sender may have queued in one mailbox (`max_mailbox_messages`) | 256 | 256 | `Process::_append_message` |
| bytes a sender may have queued in one mailbox (`max_mailbox_bytes`) | 1 MB | 32 KB | `Process::_append_message` |
| total mailbox of an untrusted process | 4 x the two above, and the sandbox heap floor | 4 x the two above, and the floor | `Process::_append_message` |
| message size (`max_message_bytes`) | 256 KB | 8 KB | `process_send` |
| live timers per process (`max_timers`) | 64 | 64 | `timer.create` |
| live processes per group (`max_processes`) | 1 | 1 | `Scheduler::spawn` |
| uninterrupted run time (`max_run_time_us`) | 2 s | 2 s | `Scheduler::tick` |
| total CPU time (`cpu_budget_us`) | unlimited | unlimited | `Scheduler::tick` |
| allowed-target set (`max_send_grants`) | 64 | 64 | `ProcessGroup::grant_send_to` |

On a device the heap quota alone does not keep memory for the system: the
128 KB default is more than a classic ESP32 has free with WiFi up (about 75
KB), so a sandbox could grow until the system had less than 1 KB free, and
an install's verification (in the system process) ran out of memory. A
sandboxed process's heap therefore also leaves a floor of the system heap
free: it doesn't take new heap pages (`TwoSpaceHeap::max_external_allocation`)
or external byte arrays and strings (`AllocationManager::alloc`) when that
would leave less than `CONFIG_TOIT_SANDBOX_HEAP_FLOOR_KB` (default 32 KB,
0 turns it off) free in the system heap (`heap_caps_get_free_size`). A
sandbox that needs more gets `OUT_OF_MEMORY` as at its quota (after the
usual collections). The floor is checked when the sandbox grows: memory it
already holds isn't taken back, so trusted code that later needs more
(WiFi coming up) can still find less free (see "When the system process
itself can't allocate" below for what happens then). On the host the floor
works on a simulated system heap (`-Xsandbox_heap_floor`,
`-Xsandbox_system_heap`) that holds the heaps of all sandboxed processes
(each counts itself when it grows and is removed when it ends) and the
messages charged to the floor (tests/sandbox/heap-floor-test.toit).

The floor also applies to:

- **Starting a sandboxed container.** `programs_registry.spawn` (and
  `snapshot.launch` on the host) refuses a sandboxed start with
  `QUOTA_EXCEEDED`, before allocating anything, when the system heap has
  less free than the floor plus what a start needs
  (`CONFIG_TOIT_SANDBOX_START_KB`, default 16; host `-Xsandbox_start_bytes`)
  (`Process::sandbox_start_allowed`). Before, the initial heap page, method
  table, globals, process and group of a (re)started sandbox were taken
  however little was left: in a two-worker device run a worker that kept
  dying of `OUT_OF_MEMORY` was restarted 4 times in 5 seconds with the
  system heap at 1-5 KB. A program whose sandboxed runs keep dying after
  running out of memory (a run that ends with a nonzero exit value after an
  allocation of its group failed) is also restarted with a delay: its next
  sandboxed start is refused for 1 s after the end of such a run, doubling
  for each such run in a row up to 32 s, reset after 60 s without one
  (`SandboxRestartDamper` in `src/out_of_memory.h`, keyed by the program
  id). A run that handles its out-of-memory errors and ends normally doesn't
  count. Each refusal prints `[sandbox start refused: ...]` with the reason.
  Trusted containers are not affected. Test:
  tests/sandbox/sandbox-start-floor-test.toit.
- **Messages to and from sandboxes.** A message queued at a sandboxed
  process, or sent by one (a messaging-restricted sender), is refused when
  it would leave less than the floor free
  (`Process::message_floor_allows_locked`), except a message from a trusted
  sender to a sandbox whose mailbox is empty (so the sandbox runs and
  learns of what it lost, see "Replies that can't be sent"). The sender
  gets the outcome of a full mailbox: `QUOTA_EXCEEDED` for a sandboxed
  sender, a dropped message (`process_send` returns false) for a trusted
  one. Before, these messages were bounded only by the mailbox quotas
  above (on a device 4 x 32 KB from trusted senders per sandboxed
  receiver, more than the free heap with WiFi up); in the two-worker device
  runs 27-37 KB of message buffers (~220-byte "external byte array"
  allocations, the tag of message buffers) appeared and stayed just before
  the trusted controller ran out of memory, most likely its replies queued
  at a worker that kept a message it could not handle while it kept
  calling. Test: tests/sandbox/reply-to-full-sandbox-test.toit.

Still not covered: a sandbox's resources (bounded by the quotas above and
the resource-group limit).

An allocation that still fails after the collections prints a heap report
(`report_allocation_failure` in `src/out_of_memory.cc`; on a device
`OS::heap_summary_report` walks the whole heap and prints for about 100 ms;
on the host it is one `Out of memory process` line). A sandbox at its quota
or at the floor can fail allocations continuously, and each failure printed
a full report (397 in one device run, followed by a hang). The reports of
every process group but the system process's are therefore rate-limited:
the first failure is reported, then at most one report per group every 10
seconds; the failures in between are only counted, and the next report is
preceded by `[out of memory: N more failed allocations of process group G
since its last heap report]`. The system process is always reported
(tests/sandbox/oom-report-rate-test.toit, tests/ctest/out-of-memory-report-limiter-test.cc).
The report's walk of the processes copies what it prints (pid, program id)
under the scheduler lock: it used to print from process pointers after the
lock was released and read a process that had terminated meanwhile (a
LoadProhibited crash on a device; tests/ctest/process-chunk-walk-test.cc).

When the system process itself can't allocate after the collections, it
restarts the device (`Out of memory in system process`, `OS::out_of_memory`;
the host VM aborts). In the 8-hour device soaks that was the main cause of
restarts, every time in starting an installed container right after an
install (format 1: `out of memory in primitive 34:1`, programs-registry
`spawn`; format 2 likewise). The primitives the system process calls while
it serves a request for another process now fail instead: they mark their
call (`ObjectHeap::set_allocation_failure_recoverable`), and an allocation
failure of a marked call, after the usual collections and the last attempt,
throws an out-of-memory error into the system code
(`[out of memory in system process: the operation fails, no restart]`). The
system code fails the request after one more attempt 100 ms later
(`with-out-of-memory-retry_`, `system/out_of_memory.toit`):

| Request | Primitives | The requester gets | What is undone |
|---|---|---|---|
| start a container (`containers.start`, also at boot) | `programs-registry.spawn` | `OUT_OF_MEMORY`: the container is refused (`Container.start`); at boot it is refused like one the verifier rejects and the other boot containers start (before: a restart, which booted again); a refused run-critical container still ends the system | nothing to undo: a failed spawn frees what it allocated |
| open an image writer | `flash.reserve-hole`, `image.writer-create` | `OUT_OF_MEMORY` | the registry's hole is adjusted only after the reservation exists; the reservation is closed if the writer can't be created |
| commit an image | `image.writer-commit` (tried 4 times, as for the verifier's `OUT_OF_MEMORY`), then `flash.get-header-page` | `OUT_OF_MEMORY` | a committed allocation whose header page can't be read back has its header page erased (`FlashAllocation.committed`): no valid allocation unknown to the registry is left in flash |
| storage regions and flash buckets | `flash.reserve-hole`, `flash.allocate`, `flash.get-header-page`, `flash.get-all-pages`, `flash.grant-access`, `flash.partition-find` | the call throws (`OUT_OF_MEMORY`, `MALLOC_FAILED` or `ALLOCATION_FAILED`) | as above; a bucket's cached entries change only after the new allocation is written (before, a failed set left the new value in the cache) |
| WiFi connect, establish and scan (the network service) | `wifi.init`, `connect`, `establish`, `setup-ip`, `set-hostname`, `get-ip`, `init-scan`, `start-scan`, `read-scan`, `ap-info` (the driver's `ESP_ERR_NO_MEM` included) | `OUT_OF_MEMORY` (connect, establish) or `MALLOC_FAILED`/`ALLOCATION_FAILED` (scan): the connect fails, the device keeps running | a registered resource is unregistered, the driver and the netif are deinitialized by the failing primitive; `NetworkState.up` disconnects a module whose connect failed; a read scan whose records were taken has lost them |

The WiFi driver needs about 65 KB to come up (63 KB free with WiFi up on a
classic ESP32, 128 KB before). A fixed floor can't cover that transient:
when sandboxes have grown before WiFi connects, the driver's allocations
failed and the system process restarted the device at every boot's first
WiFi connect (device runs with three workers, or one worker and a
container allocating until refused: 6 and 12 restarts).

Sandboxed containers lose first: for requests of trusted code and the
system's own operations (the WiFi connect and establish, the start of a
trusted container, opening an image writer; never the start of a sandbox),
`with-out-of-memory-retry_ --relieve` stops the running sandboxed
containers one at a time after the retry failed, the one reserving the
most memory first (`ContainerManager.evict-sandbox_`; a critical
container never), each followed by another attempt, and fails the request
only when none is left (`[out of memory in system process: stopping
sandboxed container G (N bytes)]`). The clients of a stopped sandbox see
the exit code 243 (`containers.EXIT-EVICTED`). A trusted controller that
restarts it is refused while the memory is short (the start floor above).
Asking the sandboxes to give memory back before stopping one needs no
request: each failed allocation was already tried again after a
collection of every process (which returns their free old-space pages).
Not done: restarting the stopped sandboxes when the operation is over
(left to their trusted owner, which the start floor and the restart delay
pace), stopping by an explicit priority (there is none; the largest goes
first), and relief for the system process's own Toit allocations (its
objects, the RPC broker, DNS lookups in the system process), which still
restart the device. Host test: tests/sandbox/system-oom-relief-test.toit
(with the container start failing twice, a running sandbox is stopped and
the trusted start succeeds; before, it failed). The WiFi part is compiled
for the ESP32 only.

Every other allocation failure of the system process (its own objects, the
RPC broker's messages, the services' bookkeeping) still restarts the
device: there the system process can't continue in a known state. Host
test: tests/sandbox/system-oom-request-test.toit, with
`-Xinject_system_oom=SITE:N` (host only), which fails the next N
allocation attempts at a site of the system process; before, the VM
aborted.

Silence at the limit: two device runs at the limit ended without output
and without a dead-lock reboot. The only hang detector on the classic
ESP32 is the dead-lock check of the scheduler's tick (a process running
for 10 s without progress), which runs on the main task under the
scheduler lock; no watchdog is armed (`OS::feed_watchdog` does nothing
there, the task watchdog is not initialized, the interrupt watchdog is
off). So a silence is either a live device whose printing containers ended
(the trusted controller died of `OUT_OF_MEMORY`, and the memory it freed
ended the sandboxes' failures and their reports) or a hang that keeps the
tick from running (the scheduler lock held by a blocked thread, or the
main task's core starved by the higher-priority WiFi, lwIP or event-loop
tasks); a primitive of the system process that blocks forever (an ESP-IDF
WiFi call waiting for a WiFi task that failed to allocate, in
`wifi-close_` -> `WifiResourceGroup::tear_down` -> `esp_wifi_stop`)
would be caught by the tick, unless the tick itself is blocked.
`CONFIG_TOIT_HEARTBEAT_S=N` (default 0) prints a heartbeat line every N
seconds from the tick and every process end, so a device run can tell
these apart.

The heap report of an allocation that failed in a primitive names the
primitive (`out of memory in primitive M:I`, module and index of
`src/primitive.h`); format 2 printed `0:0` for every primitive before
(`v2_primitive_failed` didn't pass them on). On the host the one-line
report prints the marker too.

The per-sender mailbox quotas protect every receiver, including the
system process and trusted providers, from being flooded by a sandbox. An
untrusted sender gets `QUOTA_EXCEEDED`; for a trusted sender a message to a
full sandboxed mailbox is dropped (`process_send` returns false), so a
sandbox can't make the system process throw (an RPC reply is replaced by an
error reply, see below). The sandbox heap floor bounds these messages
further (see "Quotas"). The per-sender quotas are
enforced per receiver on the messages of all sandboxed senders together
(see "Threats tested" below).

### Replies that can't be sent

An RPC reply is an ordinary message: it counts against the quotas, and
sending it can fail. The broker (`RpcBroker.send-reply_` in
`lib/rpc/broker.toit`) never lets that failure escape: before, the
exception escaped the RPC processing task and terminated the provider
process. What a client whose reply can't be sent observes:

| Provider | Why the reply can't be sent | What the provider does | What the client observes |
|---|---|---|---|
| any | it can't be serialized, or it exceeds the provider's `max_message_bytes` (trusted containers can have that quota too) | sends a short exception reply with the error | the call fails (`QUOTA_EXCEEDED`, `SERIALIZATION_FAILED`, ...) |
| trusted | the client is a sandbox and its mailbox refuses the reply (full, or the sandbox heap floor) | nothing: the send returns false, the provider is never blocked; the VM queues an error reply `[id, true, "QUOTA_EXCEEDED", null]` in its place (`Process::queue_reply_notice_locked`, the id read from the refused reply); these may exceed the quotas by 8 and the floor by 1 KB (all sandboxes together); beyond that the reply is dropped as before | the call fails with `QUOTA_EXCEEDED` once the client processes its messages (before: no reply, the call waited until its own timeout); only beyond the allowance it still waits |
| sandboxed (granted to provide services) | the mailbox share of sandboxed senders at the client is full (the provider's own messages, or another sandbox's) | retries with an exponential backoff (1 ms to 100 ms) for 5 s, then sends the exception reply, then drops it | the real reply, once the client processes its messages; after 5 s the call fails with `QUOTA_EXCEEDED`, or, if the share is still full, waits until its own timeout |
| sandboxed | the reply exceeds the provider's quotas | the same: a sandbox can't tell a reply that is too large from one to a full mailbox (both `QUOTA_EXCEEDED`) | the call fails with `QUOTA_EXCEEDED` after 5 s |

A trusted provider never retries: a sandboxed client that doesn't process
its messages must not hold the provider's processing tasks. The retries
of a sandboxed provider slow down only the sandbox (each one holds one of
its processing tasks); they stop early when the client cancels the call
(its timeout sends a cancel) or goes away. The traffic between trusted
processes is unchanged, except that a reply that can't be serialized or
exceeds a quota fails the call instead of terminating the provider.

A request or reply can also be lost to memory exhaustion at the receiver:
the task that processes the messages takes the decoded message from the
mailbox and then runs its handler (`Rpc.on-message` for a reply,
`RpcBroker.on-message` for a request), which needs stack and may need to
grow it or allocate. Before, a handler that ran out of memory lost the
message (the exception was swallowed with the other handler exceptions), and
the caller waited forever (the soak workers on a small device; since
1a19d3df only the caller itself got the error, not when another task
processed the reply, and lost requests stayed lost). Now
(`process-messages_` in `lib/core/message_.toit`):

| Where | Out of memory in | What happens | What the caller observes |
|---|---|---|---|
| client | the reply handler | the reply is kept (`deferred-message_`) and handled again, first, by the next message processing; the task that processes the messages gets `OUT_OF_MEMORY` | its reply, once memory is back; if it is the processing task itself (it processes messages while it waits), the call fails with `OUT_OF_MEMORY` |
| provider | the request handler, before the request is enqueued | an `OUT_OF_MEMORY` error reply, sent from a preallocated reply list (`RpcBroker.on-out-of-memory`); if even that message can't be allocated, the request is kept and handled again as above | the call fails with `OUT_OF_MEMORY` (or gets its reply) |
| provider | the request handler, after the request was enqueued | nothing more: the request is processed (the broker records the last enqueued request, so a kept request is not enqueued twice) | its reply |
| provider | building or sending the reply (processing task) | the full reply is retried with the backoff of a full mailbox for 5 s, then an `OUT_OF_MEMORY` error reply is retried (at most 1 s apart) for 10 s (`RpcBroker.send-out-of-memory-reply_`) | its reply, or `OUT_OF_MEMORY`; no reply only if the provider can't allocate a short message for 15 s |
| provider | taking the next request from the queue (processing task) | marks the request as being processed before it unlinks it; on the error it yields and tries again | its reply |
| either | the processing itself, before the handler ran (decode, the handler's first frame) | a message that can't be decoded stays in the mailbox (VM, unchanged); one that was taken is kept as above | as above |

While a message is kept, the other messages stay in the mailbox (as behind
one that can't be decoded), and every message processing ends with an
out-of-memory error for the task that processes the messages, so a process
with a kept message can't go to sleep: the message is either handled or the
process's tasks learn that it is out of memory. A task that yields or
suspends while other tasks of its process run leaves the error to them (it
is not thrown into it): a task that caught the error and waited again would
otherwise spin without letting the tasks run that may free memory. A task
that ends doesn't end the process with the error (`Task_.evaluate_`).
The exception of a handler that fails for another reason is traced as
before, but the trace now goes to the system process directly while the
process processes its messages (`send-trace-message` in
`lib/system/trace.toit`): its lookup of the trace service was an RPC call,
whose reply only the message processing it was part of could have taken
from the mailbox, so the process stopped processing messages for good
(tests/trace-in-message-handler-test.toit).

None of these paths can be driven by a sandboxed client: the handlers drop
malformed messages without throwing, so they only fail when the receiver
is out of memory; a kept message is handled again with bounded work; the
provider's retries hold one processing task (of the 8 a sandboxed client
may use) for at most 15 s; and the system process never gets there, since
it restarts the device when it is out of memory (except in the primitives
of the requests it serves for others, whose failure fails the request: see
"When the system process itself can't allocate" above). Exempting replies from the
quotas was rejected for the reasons below; a reply that a trusted provider
can't deliver to a sandbox's full mailbox is replaced by a small error
reply within a fixed allowance (the table above), so the sandbox's call
fails instead of waiting, and the trusted side's replies can't pile up
behind a sandbox that doesn't process its messages (the quotas and the
floor bound them; the provider's send never blocks).

What is left: a process can still run out of memory so thoroughly that none
of its tasks can make a call (a task's stack can't grow, and the memory is
held by a task that can't run). Its RPC processing task then ends with the
error (and the process with it, as before), or the process stays stuck
until memory comes back from elsewhere. A stress program (a provider at a
100 KB heap limit that is out of memory about 900 times per 1000 calls,
opentoit-sandbox-artifacts/liveness/progs/host/rpc-provider-oom-stress.toit)
lost a call in every run before (26 of 26); now no call is lost, 84 of 100
runs complete, in 9 the provider process ends and in 7 it stays stuck for
more than 20 s. Ending the process is visible to service clients
(`NO_SUCH_PROCESS`); being stuck is not.

Exempting replies from the quotas was rejected: the VM can't tell a reply
from a forged `SYSTEM_RPC_REPLY` (`forge-rpc-reply`), so an exemption
would let a sandbox queue unbounded memory in any receiver it may send
to. Charging replies to per-request credits in the VM would bound that,
but forged replies would use up the credits, so the broker would still
have to handle the failure.

Service providers bound what a sandboxed client can make them hold. These
limits live in the Toit libraries and apply to sandboxed clients only:

| Limit | Value | Enforced in |
|---|---|---|
| unprocessed RPC requests of one sandboxed process in a provider's broker | 8 (half the processing tasks) | `RpcBroker` (`lib/rpc/broker.toit`) |
| open clients of one sandboxed process at one provider process | 32 | `ServiceManager_.open` (`lib/system/services.toit`) |
| services registered by one sandboxed process (only with the grant, see above) | 16 | `SystemServiceManager.listen` (`system/services.toit`) |
| pending discoveries (`discover --wait`) of one sandboxed process | 16 | `SystemServiceManager.discover` |
| size of a registered uuid, name or tag; number of tags | 128 bytes; 8 | `SystemServiceManager.listen` |

Exceeding a count throws `QUOTA_EXCEEDED` in the sandbox (a full broker
replies "Cannot enqueue more requests"), a size `INVALID_ARGUMENT`.
Registrations with values of the wrong type are refused for every
provider, and every receiver drops RPC and trace messages with a
malformed payload instead of throwing.

A process with a run-time limit is preempted after half the limit; if it
is still running at the next scheduler tick after the full limit (for
example because it is stuck in a primitive), it is killed with exit code
241. The same exit code is used when the CPU budget is exhausted. This
replaces the `PROCESS_MAX_RUN_TIME` dead-lock `FATAL` for such processes.
A kill takes effect when the running primitive returns.

`HALT 2` (deep sleep) and `HALT 3` (reset) are rejected by the verifier
in untrusted programs (see below), so such a program never starts. As a
second line of defense, an untrusted process that reaches them anyway is
terminated with exit code 242 instead of acting on the device.

A container explicitly started as untrusted through the container API is
never critical: its failure doesn't terminate the system, even if its
image has the run-critical flag.

## Firmware without sandboxes

Sandboxed containers are opt-in, and a firmware that runs only
first-party code should not pay for them. The build option `TOIT_SANDBOX`
decides whether a VM has them:

| build | option | default |
|---|---|---|
| ESP-IDF firmware | Kconfig `TOIT_SANDBOX` (menu Toit; needs `TOIT_VERIFIED_CORE`) | **off** |
| hosts (`make sdk`, CMake) | CMake `-DTOIT_SANDBOX=ON\|OFF` | on (the SDK makes the certificates of untrusted programs and runs the sandbox tests) |
| EC618 | `make ec618 EC618_BYTECODE_FORMAT=2 EC618_SANDBOX=ON` | off |

A firmware that installs or runs untrusted containers needs, besides
the format-2 lines of docs/format2-migration.md ("Devices"):

    CONFIG_TOIT_SANDBOX=y

Without the option (`TOIT_NO_SANDBOX` in the C++; also every build
without the verified core):
- an untrusted start or launch (`containers.start --untrusted`, an image
  flagged untrusted, `snapshot.launch`, `toit.run --untrusted`) fails
  with `SANDBOX_NOT_SUPPORTED` (`PrimitivePolicy::from_description`),
  before the heap-floor check and before anything is allocated;
- an install of an image flagged untrusted (`ContainerImageWriter.commit
  --untrusted`, the flash registry's program installs) fails with
  `SANDBOX_NOT_SUPPORTED` (`V2Verifier::install_verdict`) before the image
  is verified or its header written: no image is left behind, and the
  certificate block is not kept (no flash cost);
- the verifier is not linked, nor the untrusted policy, its primitive
  tables and its verifier arity table; `PrimitivePolicy::is_untrusted()`
  (and `restricts_messaging()`, `may_halt_device()`) is a constant false,
  so the compiler drops the code behind its checks: the messaging
  restrictions and grants of restricted senders, the heap floor and the
  restart damping of sandboxed runs, the reply notices to full sandboxes,
  the field-access checks of the C++ interpreter for sandboxed processes;
- trusted programs run exactly as with the option, on the same verified
  core, and quotas for trusted containers (`containers.start --quotas`)
  still work;
- certificates: only snapshots compiled with `--untrusted` carry one
  (`toit compile --untrusted`; trusted and first-party snapshots, Jaguar
  and the system image have none), and a device never keeps one in flash
  (the install verifies with it and erases its pages). A trusted-only
  deployment pays nothing for certificates with or without the option.

What it saves (classic ESP32, format 2, f2 configuration of
artifacts measure-3; sandbox-optional/README.md has the per-item list):

| | sandbox on (as before) | sandbox off | |
|---|---:|---:|---:|
| toit.bin | 1,461,680 | 1,423,424 | -38,256 |
| Jaguar margin to the OTA partition | +53,840 | +92,096 | +38,256 |
| static DRAM (free heap at boot) | 57,708 | 54,908 | -2,800 |
| IRAM used (free) | 130,442 (630) | 130,378 (694) | -64 |

Of the flash, 34.8 KB is the verifier (Rust and its C++ glue, most of
it pinned flash code on the classic ESP32), 3.5 KB sandbox-only C++. On
the host the trusted benchmarks run the same number of instructions
(richards, yield, task ping-pong; RPC within the GC's run-to-run
variation).

What stays in a firmware without the option, and why:
- the run loop's policy lookup in the verified core (a compare of the
  primitive's table entry, which the core loads anyway for the arity,
  against "denied"): it is proved code shared by both configurations,
  and the table of the trusted policy denies nothing;
- the quota code (heap, mailbox, message, timer, process, run-time and
  CPU quotas): trusted containers can have quotas too;
- the sandbox code of the system process (`system/`: the policy
  validation, the sandbox print service, the service limits for
  sandboxed clients and providers, the eviction of sandboxes when memory
  is short; about 0.5 KB of bytecode in the sandbox-only methods of the
  system image, no measurable heap at rest): Toit has no conditional
  compilation, and leaving it out needs a system source per
  configuration;
- the Kconfig options of the heap floor (`TOIT_SANDBOX_HEAP_FLOOR_KB`,
  `TOIT_SANDBOX_START_KB`): without sandboxes they have no effect.

The proofs are those of the configuration with sandboxes, which the
option does not change (no Rust feature differs; docs/sandbox-guarantee.md,
1.5). `verified/check.sh` section `sandbox-off` builds the host VM
without sandboxes next to the main build, checks that the verifier is
not linked and runs `tests/sandbox-off` (the refusals, and trusted
programs and quotas still working).

## Launching untrusted containers

Host:

    toit run --untrusted program.toit          # or a snapshot
    toit.run --untrusted program.toit          # or -Xuntrusted

A snapshot for an untrusted container must be compiled for it:

    toit compile --untrusted --snapshot -o program.snapshot program.toit

Format 2 is the compiler's default (docs/format2-migration.md), and by
default it compiles first-party code, with trusted-only opcodes that the
verifier rejects in untrusted programs. `--untrusted` emits only checked
opcodes and ships the certificate. `toit run --untrusted` compiles that way
by itself.

`toit.run` passes the flag to the boot program
(`system/extensions/host/toit.run.toit`) as a third entry of the spawn
arguments; the boot program marks the application image with
`FLAG-UNTRUSTED` and launches it through `snapshot.launch`, which takes
the policy as its last argument (a kind, or a list of a kind and quotas).

From a (trusted) Toit program, on host and device:

    import system.containers
    containers.start image-id arguments --untrusted
    containers.start image-id arguments --untrusted --quotas={"heap": 100_000, "cpu-ms": 500}

The quota keys are "heap", "mailbox-messages", "mailbox-bytes",
"message-bytes", "timers", "processes", "run-time-ms" and "cpu-ms".
Quotas can also be given for trusted containers. `--may-provide-services`
grants an untrusted container to register service providers (see
"Providing services is a privilege").

Device: containers are started by `system/containers.toit` through
`programs_registry.spawn`, which takes the policy as its last argument.
Without an explicit policy a container runs with the trusted policy.
`ContainerService.FLAG-UNTRUSTED` on an image (for example from
`ContainerImageWriter.commit --untrusted`, or set by `toit run
--untrusted`) is binding: a container from a flagged image always runs
with the untrusted policy, also when the start request asks for the
trusted policy (only its quotas are used). Running a container from an
unflagged image untrusted is up to the caller. Existing images are
unaffected.

Host firmware (run-image, `boot.sh`): the flash registry does not survive
a restart, so run-image backs up every installed image in
`installed-images/` and reinstalls it at the next start through the
containers service, like a fresh install. The backup keeps the flags and
the data the image was committed with and the image as it was written,
with its shipped certificate: an untrusted image is verified again and
flagged untrusted again. It keeps no verdict. Backups of older builds
have no flags; they are reinstalled untrusted (verified, and sandboxed or
not installed). A backup whose metadata doesn't match its image is not
reinstalled. Refused backups are reported on stderr and stay in place
(`containers.uninstall` deletes them); see `InstalledImageBackup` in
`system/extensions/host/run-image.toit` and
`tests/envelope/installed-flags-test.toit`.

## Verification at launch

Every program that is started with the untrusted policy is checked by the
structural bytecode verifier (`src/verifier.cc`) with the untrusted rules
before a process group is created for it: `snapshot.launch` (host) and
`programs_registry.spawn` (containers in flash) call
`Verifier::verify_for_policy`. This happens independent of `-Xverify` and
`TOIT_VERIFY`; trusted programs are still only verified when one of them
is set. A rejected program never runs: the verifier prints its errors to
stderr and the launch fails with the error `VERIFICATION_FAILED`. A
snapshot the reader rejects as malformed fails with `INVALID_ARGUMENT`.
The container manager forgets a container whose start failed; a refused
run-critical container ends the system with exit code 1 (so `toit run
--untrusted` exits with 1), and `boot` keeps booting the other images.

Builds without a verifier refuse all untrusted programs: on devices,
firmware without the verified core (`TOIT_VERIFIED_CORE`, off in the
default configuration).

Format-2 programs are verified by the Rust verifier (verified/vmverify),
which also checks the loader's contract (`loaded_ok`, proven check
`x_loaded_ok_stream`): among other things, every string literal of the
program heap must be well-formed UTF-8 (no overlong encodings, surrogates
or code points above U+10FFFF). A program with such a literal is rejected
with "a string literal isn't valid UTF-8". The check is one pass over the
string bytes: 436 bytes of device code, and no measurable time next to
the rest of the verification (the heap check of the toit CLI, 4024
objects, takes about 0.25 ms). Format-1 programs are never run untrusted
(every build refuses them with `FORMAT_2_REQUIRED`). Strings that
aren't valid UTF-8 can still arise at run time from string slices with
crafted bounds (crafted bytecode can store the fields of a `StringSlice_`);
the primitives and the message encoder cope with them (see "Threats
tested").

## Field accesses

Untrusted processes run format 2 on the verified core, whose field
accesses are proved in bounds for every program the verifier accepts
(docs/sandbox-guarantee.md). The rest of this section is about the C++
interpreter, which no longer runs untrusted processes (format 1 is refused
for them; the format-1 test, field-access-test.toit, was removed with the
flag `-Xuntrusted_format1` that allowed it).

The format-1 structural verifier did not prove the receivers of field
accesses, so the C++ interpreter checks every field access of an untrusted
process at run time, in every build. Such processes run with their own
dispatch table, which
sends the seven field bytecodes (`LOAD_FIELD`, `LOAD_FIELD_WIDE`,
`LOAD_FIELD_LOCAL`, `POP_LOAD_FIELD_LOCAL`, `STORE_FIELD`,
`STORE_FIELD_WIDE`, `STORE_FIELD_POP`) to entries that check that the
receiver is an instance (or task) with enough fields, and which calls field
accessors from `INVOKE_VIRTUAL_GET`/`INVOKE_VIRTUAL_SET` instead of
inlining them. A failing access throws `INVALID_PROGRAM`. Other processes
use the unchecked table and don't pay for the check. Builds configured with
`TOIT_CHECKED_FIELD_ACCESS` in the environment check the field accesses of
every process.

## Tests

`tests/sandbox/` contains the negative suite. Each `*-test.toit` is a
trusted driver that starts a trusted sibling container and an untrusted
container from its own image (`tests/sandbox/sandbox.toit`). The untrusted
container performs one attack, which must end in the expected Toit
exception (or in the VM killing the container with the expected exit
code); the driver then checks that the sibling still answers requests.
`heat-pump-test.toit` is the positive end-to-end test of the grant
mechanism. `tests/sandbox/cli/` holds programs run directly with
`toit.run --untrusted`, from source and from a snapshot.

## Format 1 on devices (history)

No build runs untrusted programs in format 1 any more (the host's
`-Xuntrusted_format1` was removed as well). Devices never could:

- The structural verifier (`src/verifier.cc`) is host-only. It uses the STL
  (`std::vector`, `std::unordered_map`, `std::string`) and allocates with
  throwing `new` (under `AllowThrowingNew`), and it is not compiled for
  FreeRTOS. Without it, `Verifier::verify_for_policy` refuses every
  untrusted program, so `programs_registry.spawn` with the untrusted policy
  (or an image with `FLAG-UNTRUSTED`) fails with `VERIFICATION_FAILED` on
  ESP32 and other FreeRTOS devices.
- Untrusted containers in flash are verified on every start: the result
  of the verification is not recorded with the image, so a device would
  pay for it at every boot.

The C++ verifier will not be ported to FreeRTOS. The plan is that untrusted
programs move to bytecode format 2, whose verifier is written in Rust
(`verified/`) and verified against the bytecode specification, for the
host and for install time on the device. The device verifies an image once,
when it is installed, and keeps the verdict in the flash allocation
metadata, with the verification epoch of the firmware that computed it
(verified/verification-epoch.cmake): a firmware with other install-time
checks refuses the image until it is reinstalled. This is implemented:
untrusted installs in format 2 run on the ESP32-C6, the classic ESP32 and
the ESP32-S3 with firmware built with the verified core
(docs/format2-migration.md).

## Known gaps

- Format 2 (the default for untrusted containers): the verifier is proven
  sound against the bytecode specification, and the interpreter is proven
  to follow it under the leaf contracts of the C++ it calls (allocation,
  stack growth, exception allocation, C++ primitives), the loader's and
  the scheduler's contracts and the collector's (verified/spec/SOUNDNESS.md,
  verified/core/TRUSTED.md section 6; the statement and its trusted base:
  docs/sandbox-guarantee.md). What remains unproven is the trusted list in
  verified/TRUSTED.toml and the C++ the sandbox can reach (primitives that
  stay in C++, the glue to the allocator, GC and scheduler, the program
  loader), and the policy itself (which primitives exist, the quotas): the
  spec does not model it.
- Untrusted containers in format 1 are refused by every build (install,
  spawn and launch fail with `FORMAT_2_REQUIRED`), so the C++ interpreter
  hardening and the unproven C++ verifier are not part of the sandbox. The
  host flag `-Xuntrusted_format1` / `TOIT_UNTRUSTED_FORMAT1=1` that ran
  them on the C++ interpreter was removed; a build without the verified
  core refuses every untrusted container.
- Untrusted images are verified once at install with the shipped
  certificate and the verdict is recorded with the verification epoch;
  after a firmware update that changes the install-time checks, installed
  untrusted containers are refused until they are reinstalled (the
  certificate is not kept, so the device cannot verify them again). The
  epoch says which checks ran, not that they are right: a bug in checks
  that did not change survives an update. Untrusted installs run on real
  hardware (see "Format 1 on devices (history)").
- A sandbox can make the system process print a warning for every
  unhandled message it sends, and print and trace as fast as the system
  process writes (rate bounded only by the mailbox quota and the system
  process' speed). The plan is a general per-client budget for service
  calls, from which print, trace and log limits follow
  (docs/sandbox-service-limits.md).
- Native allocations made on behalf of a process (message buffers, timers,
  finalizer nodes) are bounded by the quotas but not charged to its heap;
  resource groups are bounded (64 per sandboxed process).
- A kill takes effect only after the running primitive returns. The C++
  primitives of the untrusted set are audited to be bounded by their
  quota-bounded arguments (docs/sandbox-primitive-audit.md); the Rust ports
  are proven safe, not bounded in time.

## Open questions

Questions the owner has looked at and left open on purpose; the tests
named assert the current behavior and must change with a decision.

- **Mailbox quotas are per receiver** (`mailbox-quota-scope`). The
  per-sender mailbox quotas are enforced per receiver, on the messages of
  all sandboxed senders together. So one sandbox can occupy the mailboxes
  of several receivers at once (the system process and up to 64 granted
  providers: 65 x 1 MB on hosts, 65 x 32 KB = 2 MB on devices, held while
  the receivers are slow), and one sandbox that fills a slow receiver's
  mailbox locks every other sandbox out of it (also the replies of a
  sandboxed provider to a trusted client, which are then delayed or
  fail; see "Replies that can't be sent"). Owner's position:
  per-sender (per-group) accounting across receivers is to be
  investigated; until then the shared per-receiver bound stays. A
  per-client budget for service calls doesn't solve it (the messages are
  queued before a provider sees them; docs/sandbox-service-limits.md).
- **Discovery's `watch` reveals pid liveness** (`watch-pid-probe`). A
  sandbox can watch any pid: a missing pid is answered at once with a
  termination notification, a live one reports its termination later, so
  the sandbox learns which processes exist and when they die, also for
  processes it may not talk to. Closing it needs the system process to
  check the watcher's grants, which needs a new primitive (and changes the
  verified core's primitive table). Owner's position: accepted for now,
  on the list. A budget for service calls would bound the rate of such
  probes, not the leak.

## Threats tested

Adversarial tests of the message gate and the quotas. Each test is in
`tests/sandbox/`; "holds" means the test asserts the expected outcome,
"fixed" that the test found a bug that was fixed with it, and "gap" that
the test asserts the current (unwanted) behavior of an open design gap
and must be updated when the gap is closed.

| Threat | Expected outcome | Test | Result | Open decision |
|---|---|---|---|---|
| Send to guessed or scanned pids | `PERMISSION_DENIED` for live and missing pids alike | `send-scan-pids`, `send-arbitrary-pid` | holds | |
| Send to a provider before its discovery returns (race the grant) | denied until the system process issues the grant, which it does before it replies | `grant-lifecycle` | holds | |
| Reuse the pid of a dead provider | the old grant is inert (send returns false); a new provider gets a new, larger pid that the old grant doesn't cover | `grant-lifecycle` | holds; pids are a 32-bit counter (`Scheduler::next_process_id`) that would only wrap after 2^31 process creations | |
| Send to an exited pid of the own group | | | not applicable: a sandbox can't spawn (`core-spawn`, `quota-processes`) | |
| Forge system message types (terminated, spawned, notify-terminated, external notifications, reserved types) | `PERMISSION_DENIED` | `forge-*` | holds | |
| Forge RPC replies and resource notifications for another process' pending requests; cancel them | no effect (replies and cancels are matched on id and sender pid) | `forge-rpc-reply` | holds; the test failed in about 15% of runs under load: the forged messages filled the driver's mailbox share, so the sandbox's own reply to the driver's `close` failed and terminated it (fixed with the next row) | |
| Make a provider's reply fail: ask a trusted provider with a message size quota for a large reply; fill a trusted client's mailbox share (from another sandbox, or the provider itself) so that a sandboxed provider's reply doesn't fit | the call fails or is delayed, the provider keeps serving its other clients | `rpc-reply-too-large`, `rpc-reply-full-mailbox` | fixed: `QUOTA_EXCEEDED` escaped the broker's processing task and terminated the provider (a sandbox could take a trusted provider with a `message-bytes` quota, or another sandbox's service, away from every client). See "Replies that can't be sent" | |
| Use, close, or close resources of another process' service clients (known client ids, guessed handles) | `SERVICE_CLIENT_NOT_OWNED` | `forge-client-id` | holds | |
| Malformed `SYSTEM_RPC_REQUEST`, `_CANCEL` or `SYSTEM_TRACE` payload (null, byte array, empty list, non-integer id or name) to the system process or a provider | dropped | `forge-rpc-request-malformed` | fixed: a single message killed the receiver (the system process and with it the VM, exit code 1) | |
| Flood one mailbox | `QUOTA_EXCEEDED` at the per-sender quota | `flood-system`, `mailbox-flood-provider`, `mailbox-*-flood-self`, `message-too-large` | holds per receiver | |
| Flood every receiver it may send to | memory bounded per sandbox | `mailbox-quota-scope` | gap: the quota is per receiver, so a sandbox fills the system process and its 64 granted providers: 65 x 1 MB (host) or 65 x 32 KB = 2 MB (device) of malloced buffers held by slow receivers | open: see "Open questions", mailbox quotas per receiver |
| Lock other sandboxes out of a receiver | each sandbox has its own quota at a receiver | `mailbox-quota-scope` | gap: the quota counts the messages of all sandboxed senders together, so one sandbox that fills a slow receiver's mailbox locks every other sandbox out of it | open: see "Open questions", mailbox quotas per receiver |
| Fill the system process' RPC queue (requests without waiting for replies) | other containers' requests to the system process succeed | `rpc-queue-flood-system` | fixed: about 2% of a trusted client's requests failed with "Cannot enqueue more requests" | |
| Take all processing tasks of a provider with slow requests | other clients are served | `rpc-slow-requests` | fixed: a trusted ping waited 2.5 s | |
| Register many services, pending discoveries or clients, with large strings | bounded memory in the system process | `discovery-quota` | fixed: the VM grew by 1.5 GB in 6 s | |
| Register a malformed service (wrong value types) for a trusted service's uuid | refused | `listen-malformed` | fixed: a tag that wasn't a string made every client with a restricted selector (including `deny --tag="untrusted-provider"`) throw | |
| Malformed calls to discovery and the sandbox print service (wrong types and shapes, bad method indexes, deep nesting, large arguments) | exception reply, the system process keeps working | `system-service-malformed` | holds | |
| External byte arrays in messages | charged to the mailbox quota like copies (the message size includes externals) | `message-too-large` | holds (primitive audit) | |
| Uncharged native memory: resource groups from `timer.init` in a loop, adding and removing a finalizer in a loop, `remove_finalizer` on an external byte array | charged to the container or bounded | `resource-group-churn`, tests/`finalizer-churn-test`, tests/`remove-finalizer-external-test` | fixed: 64 bytes of VM memory per call; 200 MB per 5M finalizer toggles; the external memory leaked; `get_generic_resource_group` had the same problem and is no longer allowed (`core-get-generic-resource-group`) | |
| Keep a scheduler thread inside a primitive (a kill only takes effect when it returns): `process_send` of a shared object graph, `bitmap.blit` with zero strides | the primitive stops early | `message-shared-graph`, `blit-unbounded-work` | fixed: days and hours per call; the other C++ primitives of the untrusted set are linear in their quota-bounded arguments (docs/sandbox-primitive-audit.md) | |
| Read what other processes freed | new memory is cleared | tests/`off-heap-byte-array-cleared-test` | fixed: `create_off_heap_byte_array` returned uninitialized malloc memory (99% of the bytes still held freed data); it is no longer allowed for untrusted programs (`core-external-byte-array`), and large `ByteArray`s are cleared (`cli/large-byte-array`) | |
| Send strings that aren't valid UTF-8 (crafted literals or string slices) to receivers that rely on valid ones; over-read with them | crafted literals rejected at launch; strings from crafted slices refused when sent, conversions stay inside the string | `invalid-utf-8-literal`, `cli/invalid-strings-snapshot` | fixed: delivered to the system process; `string-to-utf-16` read up to 7 bytes past the string. The literals of format-2 programs are now checked at launch (`loaded_ok`); the run-time checks make the strings with cut string slices (they used a format-1 program while untrusted format 1 could be allowed) | |
| Create processes or groups; write flash | denied | `core-spawn`, `quota-processes`, `system-container-service`, `system-storage-service`, `module-flash-registry` | holds; no other path found | |
| Starve the scheduler: tight loop, the longest primitives on 16 MB objects (15 ms on the host), recursion, 100 yielding tasks | the sibling and the system process answer within a few ms | `scheduler-starvation` | holds (also with the VM pinned to one core); run-time limit and CPU budget: `quota-run-time`, `quota-cpu-budget` | |
| Raise the own priority | denied | `core-process-set-priority` | holds; no other path found | |
| Survive the own kill (services, used clients, queued messages, pending discovery, timers, tasks, finalizers) | all gone; clients of its services fail | `kill-cleanup` | holds | |
| Read process statistics | denied | `core-process-stats` | holds | |
| Probe pids and observe process lifetimes through the discovery service's `watch` | no information about processes it may not talk to | `watch-pid-probe` | gap: a watch of a missing pid is answered at once with a termination notification, a watch of a live process reports its termination | accepted for now: see "Open questions", `watch` reveals pid liveness |
| Provide a service a trusted client expects before the trusted provider is up | trusted clients don't use sandbox providers | `provider-denied`, `service-squat`, `provider-grant` | fixed: without a trusted provider a plain selector opened the sandbox's. Registration is now refused unless the launch policy grants it, and granted providers are only discovered by trusted clients that opt in | |
| Reach a trusted container's service by its uuid | only services meant for sandboxes | `heat-pump` | fixed: providers outside the system process accepted sandboxed clients unless they opted out. Serving sandboxes is now opt-in for every provider, and discovery doesn't return (or grant) providers that don't opt in | |
| Flood the console through traces and prints | bounded output | | gap, not tested (the host's stdout is fast): every valid trace payload (up to the message size cap) is printed base64-encoded, and every unhandled message type prints a warning; on a device with a UART console this keeps the system process busy | a per-client budget for service calls: docs/sandbox-service-limits.md |
| Timing and counting side channels | | | accepted: `Time.monotonic-us` shows the load of the machine; the own pid tells how many processes were created since boot | |
