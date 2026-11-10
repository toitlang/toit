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
  `utf_16_to_string`, `byte_array_new_external` and
  `create_off_heap_byte_array` (charged to the process heap),
  `byte_array_is_valid_string_content`, `crc`, `random_seed` (per-process
  PRNG), `literal_index`, `encode_object`, `word_size`, `platform`,
  `architecture`, `vm_sdk_version`, `vm_sdk_model`, `app_sdk_version`,
  `app_sdk_info`, `gc_count`, `bytes_allocated_delta`,
  `get_generic_resource_group`, `main_arguments`, `spawn_method`,
  `spawn_arguments`.
- timer: the whole module. events: the whole module.
- bitmap: `blit` and `byte_zap`.

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
sandbox can't make the system process throw.

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

## Verification at launch

Every program that is started with the untrusted policy is checked by the
structural bytecode verifier (`src/verifier.cc`) with the untrusted rules
before a process group is created for it: `snapshot.launch` (host) and
`programs_registry.spawn` (containers in flash) call
`Verifier::verify_for_policy`. This happens independent of `-Xverify` and
`TOIT_VERIFY`; trusted programs are still only verified when one of them
is set. A rejected program never runs: the verifier prints its errors to
stderr and the launch fails with the error `VERIFICATION_FAILED`. The
container manager forgets a container whose start failed; a refused
run-critical container ends the system with exit code 1 (so `toit run
--untrusted` exits with 1), and `boot` keeps booting the other images.

Builds without the verifier (FreeRTOS devices) refuse all untrusted
programs.

## Field accesses

The verifier does not prove the receivers of field accesses, so the
interpreter checks every field access of an untrusted process at run time,
in every build. Such processes run with their own dispatch table, which
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

## Known gaps

- The untrusted policy is a dispatch-time gate only. It relies on the
  interpreter hardening (block and method-id validation) and on the
  verifier, which is not proven sound yet; a verifier bug lets a
  malicious snapshot bypass the primitive table.
- The verifier does not prove the receivers of field accesses. Only
  builds with `TOIT_CHECKED_FIELD_ACCESS` check them at run time; in
  other builds a malformed untrusted program can read and write past the
  end of an object.
- Untrusted containers in flash are verified on every start, not once at
  install time, and not at all on devices (which refuse them).
- A sandbox can make the system process print a warning for every
  unhandled message it sends (rate bounded only by the mailbox quota and
  the system process' speed).
- Native allocations made on behalf of a process (message buffers, timers)
  are bounded by the quotas but not charged to its heap.
- A kill takes effect only after the running primitive returns.
