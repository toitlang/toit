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

Process-local primitives that no ordinary program needs are left out as
well (measured on the test suite and the sandbox tests); their documented
APIs throw `PERMISSION_DENIED`:

- `byte_array_new_external`, `create_off_heap_byte_array`
  (`ByteArray.external`, `create-off-heap-byte-array`): explicit external
  memory. `ByteArray n` works for every `n`: a byte array larger than the
  largest heap allocation (about a heap page) gets an external (malloced,
  cleared) backing store inside `byte_array_new`, charged to the process
  heap. The deprecated `bytes.Buffer`, which uses `ByteArray.external` for
  backing stores above 128 bytes, falls back to an ordinary byte array.
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
- by the scheduler, when a process of an untrusted group receives an RPC
  request: the requester's pid is granted so the provider can reply.

The set holds at most `max_send_grants` pids, and grants are never
evicted: evicting an older grant would silently break a capability the
container uses. The system process and processes of the own group don't
take up room. When the set is full, a discovery that would grant a new
provider fails with `QUOTA_EXCEEDED` (the client sees the exception), and
an RPC request from a new requester to a provider in the container is
refused like a request to a full mailbox (`process_send` returns false for
a trusted sender). Pids are never reused, so grants for dead processes are
inert, but they keep their room.

Services in the system process are reachable by every process, so they
reject untrusted clients unless the provider opts in
(`ServiceProvider.accepts-untrusted-clients`). Service discovery and the
sandbox print service opt in; the container, storage, network and other
system services do not, so an untrusted container can't start containers,
use storage or open sockets. Services provided by an untrusted process
are registered with the lowest priority and the tag `untrusted-provider`,
so they can't take over services of trusted providers.

## Quotas

Quotas are installed by the launcher and can't be changed by the
program. A value of 0 means unlimited. Defaults of the untrusted policy:

| Quota | Host default | Device default | Enforced in |
|---|---|---|---|
| heap per process (`max_heap_bytes`) | 64 MB | 128 KB | `Process` constructor; `set_max_heap_size` is denied, and for trusted policies with a cap it can't raise the cap |
| messages a sender may have queued in one mailbox (`max_mailbox_messages`) | 256 | 256 | `Process::_append_message` |
| bytes a sender may have queued in one mailbox (`max_mailbox_bytes`) | 1 MB | 32 KB | `Process::_append_message` |
| total mailbox of an untrusted process | 4 x the two above | 4 x the two above | `Process::_append_message` |
| message size (`max_message_bytes`) | 256 KB | 8 KB | `process_send` |
| live timers per process (`max_timers`) | 64 | 64 | `timer.create` |
| live processes per group (`max_processes`) | 1 | 1 | `Scheduler::spawn` |
| uninterrupted run time (`max_run_time_us`) | 2 s | 2 s | `Scheduler::tick` |
| total CPU time (`cpu_budget_us`) | unlimited | unlimited | `Scheduler::tick` |
| allowed-target set (`max_send_grants`) | 64 | 64 | `ProcessGroup::grant_send_to` |

The per-sender mailbox quotas protect every receiver, including the
system process and trusted providers, from being flooded by a sandbox. An
untrusted sender gets `QUOTA_EXCEEDED`; for a trusted sender a message to a
full sandboxed mailbox is dropped (`process_send` returns false), so a
sandbox can't make the system process throw. The per-sender quotas are
enforced per receiver on the messages of all sandboxed senders together
(see "Threats tested" below). The size of a message is computed in a
primitive that can't be interrupted, so it stops as soon as the encoding
exceeds the message-size quota (a shared object is encoded once per
reference). Strings that aren't valid UTF-8 (crafted literals or string
slices) can't be sent.

A sandboxed process may have at most 64 resource groups (`timer.init`;
their memory is only freed when the process exits). With a run-time
quota, the work of `bitmap.blit` is bounded by a few passes over its
arguments.

Service providers bound what a sandboxed client can make them hold. These
limits live in the Toit libraries and apply to sandboxed clients only:

| Limit | Value | Enforced in |
|---|---|---|
| unprocessed RPC requests of one sandboxed process in a provider's broker | 8 (half the processing tasks) | `RpcBroker` (`lib/rpc/broker.toit`) |
| open clients of one sandboxed process at one provider process | 32 | `ServiceManager_.open` (`lib/system/services.toit`) |
| services registered by one sandboxed process | 16 | `SystemServiceManager.listen` (`system/services.toit`) |
| pending discoveries (`discover --wait`) of one sandboxed process | 16 | `SystemServiceManager.discover` |
| size of a registered uuid, name or tag; number of tags | 128 bytes; 8 | `SystemServiceManager.listen` |

Exceeding a count throws `QUOTA_EXCEEDED` in the sandbox (a full broker
replies "Cannot enqueue more requests"), a size `INVALID_ARGUMENT`.
Registrations with values of the wrong type are refused for every
provider.

A process with a run-time limit is preempted after half the limit; if it
is still running at the next scheduler tick after the full limit (for
example because it is stuck in a primitive), it is killed with exit code
241. The same exit code is used when the CPU budget is exhausted. This
replaces the `PROCESS_MAX_RUN_TIME` dead-lock `FATAL` for such processes.
A kill takes effect when the running primitive returns.

`HALT 2` (deep sleep) and `HALT 3` (reset) from an untrusted process
terminate that process with exit code 242 instead of acting on the
device.

A container explicitly started as untrusted through the container API is
never critical: its failure doesn't terminate the system, even if its
image has the run-critical flag.

## Launching untrusted containers

Host:

    toit run --untrusted program.toit          # or a snapshot
    toit.run --untrusted program.toit          # or -Xuntrusted

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
Quotas can also be given for trusted containers.

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

## Field accesses

The interpreter checks every field access of an untrusted process at run
time, in every build. Such processes run with their own dispatch table,
which sends the seven field bytecodes (`LOAD_FIELD`, `LOAD_FIELD_WIDE`,
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

## Known gaps

- The untrusted policy is a dispatch-time gate only. It relies on the
  interpreter hardening (stack-pointer and method-id validation) to keep a
  malformed program from jumping to code that bypasses the primitive
  table. Untrusted programs are not structurally verified before they
  run.
- A sandbox can make the system process print a warning for every
  unhandled message it sends (rate bounded only by the mailbox quota and
  the system process' speed).
- Native allocations made on behalf of a process (message buffers, timers,
  finalizer nodes) are bounded by the quotas but not charged to its heap;
  resource groups are bounded (64 per sandboxed process).
- A kill takes effect only after the running primitive returns. The
  primitives of the untrusted set were reviewed to be bounded by their
  quota-bounded arguments; the two that weren't (`process_send` of a shared
  object graph, `bitmap.blit` with zero strides) now stop early.

## Threats tested

Adversarial tests of the message gate and the quotas. Each test is in
`tests/sandbox/` unless noted; "holds" means the test asserts the expected
outcome, "fixed" that the test found a bug that was fixed with it, and
"gap" that the test asserts the current (unwanted) behavior of an open
design gap and must be updated when the gap is closed. Some of the fixes
are in the VM code that exists without the sandbox and are separate pull
requests (named in the table).

| Threat | Expected outcome | Test | Result | Open decision |
|---|---|---|---|---|
| Send to guessed or scanned pids | `PERMISSION_DENIED` for live and missing pids alike | `send-scan-pids`, `send-arbitrary-pid` | holds | |
| Send to a provider before its discovery returns (race the grant) | denied until the system process issues the grant, which it does before it replies | `grant-lifecycle` | holds | |
| Reuse the pid of a dead provider | the old grant is inert (send returns false); a new provider gets a new, larger pid that the old grant doesn't cover | `grant-lifecycle` | holds; pids are a 32-bit counter (`Scheduler::next_process_id`) that would only wrap after 2^31 process creations | |
| Send to an exited pid of the own group | | | not applicable: a sandbox can't spawn (`core-spawn`, `quota-processes`) | |
| Forge system message types (terminated, spawned, notify-terminated, external notifications, reserved types) | `PERMISSION_DENIED` | `forge-*` | holds | |
| Forge RPC replies and resource notifications for another process' pending requests; cancel them | no effect (replies and cancels are matched on id and sender pid) | `forge-rpc-reply` | holds | |
| Use, close, or close resources of another process' service clients (known client ids, guessed handles) | `SERVICE_CLIENT_NOT_OWNED` | `forge-client-id` | holds | |
| Malformed `SYSTEM_RPC_REQUEST`, `_CANCEL` or `SYSTEM_TRACE` payload to the system process or a provider | dropped | tests/`system-message-malformed-test` (#3381) | fixed in #3381: a single message killed the receiver (the system process and with it the VM) | |
| Flood one mailbox | `QUOTA_EXCEEDED` at the per-sender quota | `flood-system`, `mailbox-flood-provider`, `mailbox-*-flood-self`, `message-too-large` | holds per receiver | |
| Flood every receiver it may send to | memory bounded per sandbox | `mailbox-quota-scope` | gap: the quota is per receiver, so a sandbox fills the system process and its 64 granted providers: 65 x 1 MB (host) or 65 x 32 KB = 2 MB (device) of malloced buffers held by slow receivers | a per-sender (or per-group) budget over all mailboxes? |
| Lock other sandboxes out of a receiver | each sandbox has its own quota at a receiver | `mailbox-quota-scope` | gap: the quota counts the messages of all sandboxed senders together, so one sandbox that fills a slow receiver's mailbox locks every other sandbox out of it | per-sender accounting (memory per receiver and sender) or keep the shared bound? |
| Fill the system process' RPC queue (requests without waiting for replies) | other containers' requests to the system process succeed | `rpc-queue-flood-system` | fixed: about 2% of a trusted client's requests failed with "Cannot enqueue more requests" | |
| Take all processing tasks of a provider with slow requests | other clients are served | `rpc-slow-requests` | fixed: a trusted ping waited 2.5 s | |
| Register many services, pending discoveries or clients, with large strings | bounded memory in the system process | `discovery-quota` | fixed: the VM grew by 1.5 GB in 6 s | |
| Register a malformed service (wrong value types) for a trusted service's uuid | refused | `listen-malformed` | fixed: a tag that wasn't a string made every client with a restricted selector (including `deny --tag="untrusted-provider"`) throw | |
| Malformed calls to discovery and the sandbox print service (wrong types and shapes, bad method indexes, deep nesting, large arguments) | exception reply, the system process keeps working | `system-service-malformed` | holds | |
| External byte arrays in messages | charged to the mailbox quota like copies (the message size includes externals) | `message-too-large` | holds | |
| Uncharged native memory: resource groups from `timer.init` in a loop, adding and removing a finalizer in a loop, `remove_finalizer` on an external byte array | charged to the container or bounded | `resource-group-churn`; tests/`finalizer-churn-test`, tests/`remove-finalizer-external-test` (#3377) | fixed: 64 bytes of VM memory per call; 200 MB per 5M finalizer toggles and the leak of the external memory (#3377); `get_generic_resource_group` had the same problem and is no longer allowed (`core-get-generic-resource-group`) | |
| Keep a scheduler thread inside a primitive (a kill only takes effect when it returns): `process_send` of a shared object graph, `bitmap.blit` with zero strides | the primitive stops early | `message-shared-graph`, `blit-unbounded-work` | fixed: days and hours per call | |
| Read what other processes freed | new memory is cleared | tests/`off-heap-byte-array-cleared-test` (#3380) | fixed in #3380: `create_off_heap_byte_array` returned uninitialized malloc memory; it is no longer allowed for untrusted programs (`core-external-byte-array`), and large `ByteArray`s are cleared (`cli/large-byte-array`) | |
| Send strings that aren't valid UTF-8 (crafted literals or string slices) to receivers that rely on valid ones; over-read with them | refused; conversions stay inside the string | `invalid-utf-8-literal`; tests/`tison-invalid-utf-8-test`, `utf-16-test` (#3379) | fixed: delivered to the system process; `string-to-utf-16` read up to 7 bytes past the string (#3379) | check the literals at launch too? |
| Create processes or groups; write flash | denied | `core-spawn`, `quota-processes`, `system-container-service`, `system-storage-service`, `module-flash-registry` | holds; no other path found | |
| Starve the scheduler: tight loop, the longest primitives on 16 MB objects (15 ms on the host), recursion, 100 yielding tasks | the sibling and the system process answer within a few ms | `scheduler-starvation` | holds (also with the VM pinned to one core); run-time limit and CPU budget: `quota-run-time`, `quota-cpu-budget` | |
| Raise the own priority | denied | `core-process-set-priority` | holds; no other path found | |
| Survive the own kill (services, used clients, queued messages, pending discovery, timers, tasks, finalizers) | all gone; clients of its services fail | `kill-cleanup` | holds | |
| Read process statistics | denied | `core-process-stats` | holds | |
| Probe pids and observe process lifetimes through the discovery service's `watch` | no information about processes it may not talk to | `watch-pid-probe` | gap: a watch of a missing pid is answered at once with a termination notification, a watch of a live process reports its termination | the system process can't check the watcher's grants (it needs a new primitive) |
| Provide a service a trusted client expects before the trusted provider is up | trusted clients don't use sandbox providers | `service-squat` | gap: untrusted providers lose against trusted ones, but without a trusted provider a plain selector opens the sandbox's | should plain selectors deny `untrusted-provider` by default? |
| Reach a trusted container's service by its uuid | only services meant for sandboxes | `heat-pump` | by design: providers outside the system process accept sandboxed clients unless they override `accepts-untrusted-clients` | opt-in instead of opt-out? |
| Flood the console through traces and prints | bounded output | | gap, not tested (the host's stdout is fast): every valid trace payload (up to the message size cap) is printed base64-encoded, and every unhandled message type prints a warning; on a device with a UART console this keeps the system process busy | size and rate limits for sandbox traces and prints? |
| Timing and counting side channels | | | accepted: `Time.monotonic-us` shows the load of the machine; the own pid tells how many processes were created since boot | |
