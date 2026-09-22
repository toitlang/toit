# Native BLE helper memory checks

## Primitive retry audit (2026-09-22)

Reviewed the current Linux and ESP32 HCI primitives against the requirement
that GC occurs at primitive boundaries. No new native change was needed:

| Operation | Allocation and side-effect order |
| --- | --- |
| Initialize/open | Managed proxies precede native acquisition. Linux closes an unsuccessful socket before constructing an OS error; ESP32 unregisters and destroys an unsuccessful resource before reporting initialization failure. Native allocation failures also release resources acquired by that attempt. |
| Linux receive | Peek determines size without consuming the packet. Allocation failure returns before `recvmsg`; the one-reader contract preserves packet order on retry. |
| ESP32 receive | Allocate before copying and advancing the queue head. A producer never overwrites an occupied slot; a queue fault is terminal rather than silently dropping connection data. No managed pointer is retained by the queue. |
| Send | Linux `send` and ESP32 VHCI copy synchronously. Accepted sends return preallocated booleans, with no subsequent managed allocation that could retry an accepted operation. |
| Close | Resource disposal clears the proxy. ESP32 reports a teardown error through preallocated `HARDWARE_ERROR`, preventing allocation retry after disposal. Linux returns the existing null object. |
| Diagnostics/test factory | Diagnostics allocate their result before sampling into it. The Linux test factory allocates all managed wrappers before acquiring its socket pair and rolls back partially registered descriptors. |

Source: `src/resources/ble_hci_linux.cc`, `ble_hci_esp32.cc`,
`ble_hci_packet_linux.h` and `ble_hci_queue.h`. The packet, queue and owner CTests
pass in `build/ble-feature-audit-001`. The packet test first failed on a sandbox
Unix-socket send with `EPERM`; its unchanged outside-sandbox rerun passes. Both
logs are preserved. This turn did not inject runtime allocation failures or
reflash hardware; the actual interpreter-retry evidence remains the separately
recorded `ble-native-retry-001` campaign below. General exhausted-heap recovery
remains best effort and is not inferred from this source audit.

## Controller reader cleanup when transport close fails

The controller's common failure path cancels its owned receive task in a
`finally` block, even when transport cleanup throws before waking a pending
receive. Explicit close reports the transport-close error when no earlier
failure exists. Automatic failure preserves the original receive error,
command timeout or caller cancellation instead of replacing it with a secondary
cleanup exception. Cancellation bookkeeping runs without inheriting an expired
caller deadline, and the reader never cancels itself.

`ble-hci-test.toit` injects a transport whose close throws while receive remains
blocked. It first reproduced a `wait-closed` timeout, then passed with the fix:
the close error is preserved, a pending command receives `HCI_CLOSED`, the reader
terminates within a 200ms test bound, subsequent commands are refused, and
repeated close/join does not call transport close again. Automatic failure tests
also verify an unanswered command's deadline, a pending command's receive error,
and cancellation that unwinds instead of becoming a catchable close exception.
All retain terminal command refusal and bounded reader termination. Artifacts
are in `build/ble-controller-close-failure-001` and
`build/ble-controller-failure-cleanup-001`.

This is managed-worker cleanup evidence. It does not establish physical adapter
restoration after a native close failure or recover the broken transport. The
controller remains unusable after the error.

The protocol host applies the same rule when terminating its controller:
automatic failure preserves the protocol error and always cancels its own
reader, while explicit close reports a first cleanup error. The injected
host regression originally replaced `HCI_UNEXPECTED_PEER` with the transport
close error. It now also covers an unexpected disconnection handled by the
host's reader task, explicit close, terminal command refusal and joining both
readers within 200ms. See `build/ble-host-failure-cleanup-001`. This failure
handling does not reinterpret malformed events as successful connections.

## Managed provider heap-pressure recovery

`ble-service-heap-pressure-test.toit` constrains a separately spawned BLE service
provider to a 256 KiB process heap while two clients have confirmed pending ATT
reads. It retains 128-byte allocations until the VM raises a real allocation
failure, releases this temporary load and forces GC. Both reads must return
their exact values, both links must perform a fresh read afterward, and normal
disconnect must complete within the test's ten-second deadline.

The recorded host run reached `OUT_OF_MEMORY` after 1,480 allocations; its
compacting-GC counter advanced from 0 to 6. It exited zero after two recovered
reads, two fresh reads and disconnects. The heap-pressure, multi-client recovery
and provider-restart tests pass together (3/3, 0.70 seconds), with logs/hashes in
`build/ble-service-heap-pressure`. The OOM diagnostics in that run are expected
and are followed by an explicit successful recovery checkpoint.

This uses real VM allocation limits, service RPC and connection lifetimes with
a fake HCI controller. It does not test native RX allocation retries, incoming
radio traffic during exhaustion, uncaught provider OOM death or ESP32 allocator
behavior. The isolated provider's heap limit does not affect the radio soak.

## Native helpers

### Uncaught provider OOM: host recovery passes

Run the optional firmware integration test with a freshly built host envelope:

```sh
bash tests/ble-hardware/provider-oom-host.sh \
  build/host-ble-current/sdk/bin/toit \
  build/host-ble-current/firmware.envelope \
  build/ble-provider-oom-new
```

The provider is bundled without a boot trigger. The client verifies that exactly
one image has flags zero and explicitly starts it as a separate, non-critical
container. With two confirmed ATT reads pending, an unhandled background task
retains 128-byte allocations under a 256 KiB heap cap. Both pending reads and the
crash RPC report `NO_SUCH_PROCESS`; stale handles reject further operations; a
replacement provider serves a fresh read. The client also checks provider exit
code 1. The shell runner requires both exact completion checkpoints and actual
firmware exit 0, retaining logs, snapshots and hashes.

This passed in `build/ble-provider-oom-noncritical-003`. The earlier exit-1 run in
`build/ble-provider-oom` used critical startup containers and was not a valid
non-critical recovery test. Preparing the corrected test also found and fixed
`add-image` in `system/extensions/host/run-image.toit` unconditionally forwarding
`--run-critical` instead of the supplied boolean. The corrected client flag
assertion fails before that fix and passes afterward.

This test uses simulated HCI traffic and real host container/RPC/heap machinery.
It does not establish ESP32 OOM recovery, physical-link cleanup, native receive
queue recovery or an automatic service restart policy. It remains optional and
adds no Python or radio dependency to default tests.

### Uncaught client OOM: host cleanup passes

The same runner accepts a fourth argument `client`:

```sh
bash tests/ble-hardware/provider-oom-host.sh \
  build/host-ble-current/sdk/bin/toit \
  build/host-ble-current/firmware.envelope \
  build/ble-client-oom-new client
```

The coordinator starts a bundled non-critical client, which opens a connection
and subscription. After a subscription receive is confirmed pending and another
client has connected, the first client exhausts its 256 KiB heap in an uncaught
background task. Application cleanup stays suspended until process termination.
The provider must close the pending subscription and issue disconnect. The fake
controller holds disconnect completion: the second client must still read, while
a third is refused admission until cleanup finishes. Once released, the third
client reuses the slot and the survivor reads again. The fixture requires one
controller open for the entire sequence and final transport closure.

`build/ble-client-oom-001` records the passing checkpoints, client exit 1 and
actual firmware exit 0. This exercises actual container termination, service
watches and resource cleanup with simulated HCI; physical disconnect behavior
and ESP32 resource cleanup remain separate gates.

The Linux packet receive helper and callback queue pass AddressSanitizer,
UndefinedBehaviorSanitizer and LeakSanitizer on the current worktree. This is
helper-level coverage, not a sanitized full VM or ESP32 transport execution.

The inputs are `tests/ctest/ble-hci-packet-test.cc` and
`tests/ctest/ble-hci-queue-test.cc`. Packet tests use local datagram and
sequence-packet sockets to check allocation-failure retry, packet order,
oversize refusal, bounded copying and epoll readiness. Queue tests cover owned
copies, allocation retry, malformed/oversized packets, scan reserve/drop
accounting, terminal overflow and 100,000 concurrent producer/consumer transfers.
They do not fuzz every byte sequence or check ESP32 callback registration races.

The existing CMake test targets were rebuilt first. Valgrind 3.25.1 could not
start either target because the installed dynamic linker lacks the mandatory
memcmp redirection symbol; its output requests glibc debug symbols. This is
not a Memcheck pass or a detected program defect. Logs are
`/tmp/toit-ble-packet-memcheck.log` and `/tmp/toit-ble-queue-memcheck.log`.

For sanitizer checking, the two unchanged test sources were compiled separately
with Clang, together with a tiny replacement for the test failure reporter
(`toit::fail` prints the message and aborts). All tested transport/helper code
comes from the production headers. The replacement avoids linking the full VM
and is not evidence about the VM's own failure reporting. The helper sources,
reporter, binaries and logs are under `build/ble-native-sanitizers/`.

Build each test using:

```sh
clang++ -std=c++11 -DTOIT_DEPLOY -g -O1 -fno-omit-frame-pointer \
  -fsanitize=address,undefined -pthread \
  tests/ctest/ble-hci-packet-test.cc build/ble-native-sanitizers/fail.cc \
  -o build/ble-native-sanitizers/packet
```

Replace packet with queue for the other test. The reporter defines the variadic
`[[noreturn]] void toit::fail(const char*, ...)` and calls `vfprintf` and `abort`.
Run with `ASAN_OPTIONS=detect_leaks=1:halt_on_error=1` and
`UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1`.

The sandbox denied local socket sends and prevented LeakSanitizer's process
inspection. Both tests were then run outside it, without Bluetooth access.
Both exited zero and produced empty sanitizer logs (`packet-outside.log` and
`queue-outside.log`). The initial failures remain in `packet.log` and `queue.log`.
No hardware, capability grants, system packages or retained bonds changed.

Full transport/VM sanitizer coverage, race detection, malformed-input fuzzing,
unplug/replug stress and on-device callback teardown remain separate roadmap
gates. A clean helper test run does not close those gates.


A stateful libFuzzer target is now available at `tests/fuzzer/ble/queue.cc`, with
seven checked-in seeds and reproduction instructions in that directory. It
checks the production queue against an independently owned reference queue,
including null/short/oversize framing, reserve drops, overflow and allocation
retry. A 100000-run campaign with seed 130013 completed under ASan/UBSan/leak
detection with exit zero. Artifacts are in build/ble-native-sanitizers; successful
output is queue-fuzz-retry.log and the evolved corpus is queue-corpus-retry.
The first attempt hit libFuzzer's default RSS limit; reported startup RSS was
already about 2.5 GiB. Its log and empty OOM artifact are preserved. Repeating
from the original seven seeds with a 4096 MiB limit completed successfully.
This is bounded sequential queue fuzz coverage, not concurrency or full host
parser/state-machine coverage; exact corpus sizes and coverage counters are
runtime-specific and are not specification coverage percentages.


The concurrent queue test additionally passes ThreadSanitizer. It now runs
100000 ordinary transfers and another 100000 transfers with every first
allocation attempt failing while the producer remains active. Each retry keeps
the caller buffer unchanged and ultimately delivers the exact sequence; final
queued count is zero and no terminal fault remains. The original case is
retained. Both variants pass the rebuilt CMake target, ASan/UBSan/leak detection
and TSan with zero exit codes and empty diagnostic logs. Outputs are
queue-retry-tsan.log and queue-retry-asan.log in build/ble-native-sanitizers.
For TSan, replace `-fsanitize=address,undefined` with `-fsanitize=thread` in the
queue build command and run with `TSAN_OPTIONS=halt_on_error=1:exitcode=99`.
The sanitizer runs used the same standalone failure reporter described above.
This is dynamic race coverage of these schedules, not proof of all possible
interleavings or ESP32 memory-order/callback teardown behavior.


Source review of the ESP32 callback integration found a missing entry in the
shared FreeRTOS queue-set capacity calculation. The BLE one-entry wake queue is
now counted only when the original ESP32 controller-only transport is compiled,
and allocation uses the same constant. Both affected translation units compile
with the actual ESP32 target configuration (artifacts and diagnostics in
build/ble-native-sanitizers). This fix still needs a full firmware rebuild and
on-device saturation with other event-queue peripherals. Callback locking was
reviewed but is not covered by the host queue TSan test.


The subsequent full controller-only ESP32 rebuild passes reconfiguration,
compilation, linking and envelope generation with the wake-queue correction.
NimBLE/Bluedroid remain disabled, fault injection is off, and the selected NimBLE
host symbols are absent from the linked image. The refreshed base-envelope
SHA-256 is c52b57d171ac2815fc2a5d99cbe8dd70a1b57ac32409f9ca203bbb8a6f55c8d4.
No updated firmware was flashed; combined-peripheral saturation and callback
teardown radio validation remain outstanding.


The current legacy NimBLE configuration also builds fully for original ESP32
in build/esp32-ble-nimble-regression, using the unmodified repository SDK defaults
and a separate SDKCONFIG. Its report verifies NimBLE enabled, controller-only
disabled, actual NimBLE host symbols linked and no BleHciResource implementation.
This firmware was not flashed. Runtime regression coverage, other targets and
macOS builds remain open; the successful build does not cover those requirements.


A subsequent controller-only ESP32 build refreshes the envelope's system
snapshot after the generic RPC/service termination-watch fixes. The build and
configuration/symbol checks pass. The native toit.bin remains byte-identical
(1325472 bytes, SHA256 8ff4c89cbb50efb086978485bb46b7ddab34b25fa4acf1b793b054ce151356c2).
The system snapshot grows from 169876 to 170892 bytes; its new SHA256 is
44f6e04414991f3d0be22838eff91bdac8621931f44679d6d3730fcfdeaee0ae. The new envelope
SHA256 is 68318698331eb7bbeb3bf5f0d4a1818ca5d6f8410d1b5f1d172f25334a3c040e.
Artifacts, previous/new hashes, preserved envelopes and the build log are in
build/ble-esp32-system-refresh. This was a build only: no hardware was flashed,
and the installed host VM and its CAP_NET_ADMIN grant remain unchanged. The
running radio soak continues to test its frozen earlier firmware.

## Full host VM AddressSanitizer campaign

The isolated `build/host-ble-asan` configuration uses Clang 22.1.8, build type
`ASAN`, and `-O1 -g -fsanitize=address -fno-omit-frame-pointer` for C and C++.
The VM, compiler and native libraries are instrumented. Build commands:

```sh
CCACHE_DISABLE=1 cmake -S . -B build/host-ble-asan -G Ninja \
  -DCMAKE_BUILD_TYPE=ASAN -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  '-DCMAKE_C_FLAGS_ASAN=-O1 -g -fsanitize=address -fno-omit-frame-pointer' \
  '-DCMAKE_CXX_FLAGS_ASAN=-O1 -g -fsanitize=address -fno-omit-frame-pointer' \
  -DTOIT_PKG_AUTO_SYNC=OFF -DTOIT_TEST_EXTERNAL=OFF
CCACHE_DISABLE=1 cmake --build build/host-ble-asan --target toit.run -j 4
```

Two sanitizer-specific compatibility changes were necessary. The global
`new` overrides in `src/top.cc` allocate through `malloc`, conflicting with
ASan's `delete` interceptor. ASAN builds now use sanitizer allocation operators,
as the existing TSan configuration already does. Such builds do not enforce
`throwing_new_allowed` through those overrides. The x86 SSE byte-search routine
deliberately loads aligned words beyond a buffer's bounds; ASAN builds now use
its existing bounded `memchr` fallback. Normal builds retain both original paths.
This campaign therefore does not validate that SSE implementation under ASan.

The optional Bumble runner accepts `--snapshot-compiler` to compile fixtures
separately and run their snapshots in the sanitized VM. This avoids measuring
compiler subprocess allocation lifetime as part of a VM leak test. For example:

```sh
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 \
  /tmp/ble-bumble-venv/bin/python tests/ble-interop/run.py \
  --toit-run build/host-ble-asan/sdk/lib/toit/bin/toit.run \
  --snapshot-compiler build/host-ble-current/sdk/lib/toit/bin/toit.compile \
  --output build/ble-asan-bumble-new
```

Initial failures are retained in `build/ble-vm-asan-001`: the allocation-family
mismatch, SSE overread, source compiler leak reports, and snapshot leak reports.
LeakSanitizer warned that ptrace inspection was blocked even outside the tool
sandbox. Those reports are not accepted as a completed leak audit or dismissed
as harmless; runtime leak checking remains unresolved. The subsequent campaign
in `build/ble-vm-asan-002` explicitly disables leak detection while leaving ASan
memory-access checks and allocation-family mismatch detection enabled.

Run 002 passes all 111 BLE software tests as separately compiled snapshots and
all 27 Bumble cases with the final snapshot runner. Every test process and both
campaign runners exit zero, with no ASan diagnostics. The unchanged default
source-based Bumble path also passes 27/27; an intentionally failing compiler
aborts before any peer starts. Hashes, options, compile commands, per-case logs
and terminal results are archived. This is memory-access evidence, not a leak
check, UBSan run or race-detector pass.

The regular host VM rebuild and the existing byte-array/reader-index-of tests
also pass. Both tests pass as ASan snapshots, exercising the bounded search
fallback directly. Logs are included in run 002.

These software tests exercise the host VM, native crypto, managed BLE protocols,
GC, service lifetimes and pipe IO. They do not open a real Bluetooth socket or
exercise ESP32 callbacks. Instrumenting a transport translation unit does not
prove its hardware paths ran. The live HCI transport sanitizer campaign remains
open, and the separate frozen radio soak is untouched.

## VM shutdown leaks and LeakSanitizer child inspection

Follow-up inspection found actual ownership omissions behind the initial leak
reports. Process destruction now deallocates startup arguments if the program
never decoded them. Heap destruction frees its private GC spare chunk, which is
not in either space's chunk list. The native `process-cleanup-test.cc` fixture
runs three VM lifetimes with each spare policy, requests GC while retaining
values, and checks native chunk accounting returns to baseline after every run.

The fixture also exposed incorrect global teardown ordering: freeing the shared
spare chunk still accesses GC metadata, so metadata must be unmapped afterwards.
The host runner now calls the complete ObjectMemory teardown rather than only
unmapping metadata.

The reported ptrace warning had a VM-side cause. SubprocessEventSource shutdown
temporarily sets SIGCHLD to SIG_IGN to stop its wait thread, but never restored
the previous disposition. That discards subsequent child statuses, including
LeakSanitizer's inspection child. Shutdown now restores the saved disposition
after joining the thread. The native regression forks a child after each VM
lifetime and verifies its exact exit status remains observable. With this fix,
the same ASan/LSan invocation produces no inspection warning. No extra capability
or system policy change was needed.

The failed and intermediate evidence is in `build/ble-vm-lsan-001`. The initial
native fixture crashed during metadata teardown; its GDB stack is archived.
An early broad CTest run overlapped a rebuild and includes executable-launch
failures; it is invalid as a campaign. The subsequent stable run passes 112/112
before the signal-disposition fix. Final builds and validation are archived
separately in `build/ble-vm-lsan-002`.

Run 002 passes all 111 BLE software snapshots and all 27 Bumble cases with
`ASAN_OPTIONS=detect_leaks=1:halt_on_error=1`. All child/runners exit zero, with
no ASan/LSan diagnostics or inspection warnings. The native cleanup regression,
subprocess wait-registration, cross-process GC and process-priority checks pass
in the regular build. This adds leak-check evidence for these executed VM and
software protocol paths; it is not evidence for every VM feature.

These changes affect VM cleanup, including non-BLE applications. They do not
establish live HCI socket leak coverage or on-device behavior of the updated VM.
The earlier sanitizer-only allocation/SSE limitations still apply.

## Native Linux packet resources inside the VM

The native fixture also closes a transport from finally blocks during deadline
and task-cancellation unwinding. It checks both the local closed state and actual
peer closure, preventing an already-null managed state from hiding a live socket.
Task cancellation reproduced such a leak; close now runs its full teardown in
a critical region that ignores the caller's expired deadline. Twenty ASan/LSan
cycles pass with both modes and stable descriptors in
`build/ble-native-deadline-close-001`. Separate hardware evidence in
`build/ble-vhci-interrupted-close-001` covers ESP32 and S3: ten deadline and ten
task-cancellation closes each permit fresh controller initialization with the same
identity. Both targets complete and enter deep sleep with no native close errors.
This adds41 controller lifetimes per target, without an RF peer or active-link
cancellation claim.

Linux close now checks that the resource belongs to the supplied BLE group
before unregistering its descriptor or clearing the proxy. The foreign-group
regression in `native-linux.toit` failed against the previous VM and passes20
ASan/LSan cycles after the fix, with both packet directions usable across GC
after rejection and normal owner cleanup. The full fixture returns to8 descriptors
each cycle. `build/ble-linux-close-owner-001` preserves both results, rebuilds and
the final hooks-OFF check. This guards the primitive boundary even if a caller
bypasses the managed transport's normal ownership path.

`tests/ble-hardware/native-linux.toit` explicitly exercises the production native
send/receive primitives, ResourceState monitors, epoll registration/removal and
HCI command reader inside an instrumented VM. Its `native.testing-pair` factory
requires `TOIT_BLE_HCI_TESTING=ON` and creates two nonblocking Unix sequence-packet
sockets. Both are registered through the normal BLE resource group. The factory
sets small send buffers to exercise backpressure without excessive kernel memory.
It allocates managed result/proxy objects before opening descriptors and cleans
up partial native registration failures. Normal builds return UNIMPLEMENTED.

Run `build/ble-native-vm-001` passes 20 cycles with
`ASAN_OPTIONS=detect_leaks=1:halt_on_error=1`, exit zero and no sanitizer diagnostics.
Each cycle verifies bidirectional packet copies of 1, 7, 64 and 2048 bytes retained
through GC; a declined send predicate; repeated close; closure of blocked readers
and writers; cancellation/reuse of readers and backpressured writers; repeatable
oversize refusal; and an exact HCI Reset exchange followed by malformed-command
response failure. After cleanup, descriptor count returns to the warmed baseline
of eight, with a one-second bound for asynchronous epoll removal.

The fixture is outside default CTest because it needs a deliberately instrumented
test-hook build. For a separate ASAN build, use the configuration above with
`-DTOIT_BLE_HCI_TESTING=ON`, compile this fixture to a snapshot with the regular
`toit.compile`, then run that snapshot with the instrumented `toit.run`. Passing
`disabled` to the snapshot instead verifies rejection in a normal build. The
campaign retains its test VM separately and restores `build/host-ble-asan` to
hooks OFF; the restored build passes that negative check with leak detection.
Analysis, builds, exact hashes and both terminal logs are archived.

This adds full VM/native packet-resource coverage beyond the standalone helper
tests. It does not execute AF_BLUETOOTH socket creation/bind, management ownership,
real controller queues or USB traffic. Managed allocation-failure retry remains
covered at helper level, not injected by this factory. The root-only `/dev/vhci`
device and the occupied physical adapter were not opened or reconfigured.

The controller-only ESP32 and PSRAM ESP32-S3 firmware subsequently rebuild and
pass the scoped board regressions in `build/ble-vm-cleanup-board-001`: real
encrypted resumption/revocation/reconnect denial on S3 and separate-container
administration/storage restart on original ESP32. See the board matrix for
terminal counts, capture exits and limitations. This does not instrument the
ESP32 transport with host sanitizers or measure native spare reclamation there.

Follow-up `build/ble-native-peer-close-001` adds opposite-endpoint closure while
the native reader is waiting and while the native writer is backpressured.
Both return HCI_TRANSPORT_ERROR within one second in each of 20 cycles. The full
fixture passes with ASan/LSan, exit zero and no sanitizer report; descriptor count
returns to eight each cycle. The ordinary VM still rejects the test factory.
This exercises epoll peer-error wakeups, distinct from local resource disposal;
physical Bluetooth unplug/reset and allocation-retry injection remain separate.

`build/ble-native-retry-001` subsequently closes the Linux primitive allocation
retry gap with a hook behind `TOIT_BLE_HCI_TESTING`. A dedicated resource group
declines receive allocation until the interpreter performs a full GC. Each of
20 cycles requires positive injection count, an advancing GC counter, two exact
packets in order, an empty queue afterward and retained bytes across further GC.
The full native fixture passes under ASan/LSan with eight descriptors after each
cycle. The ordinary ASan build is restored with hooks OFF and rejects factory,
injection and counter actions. This tests actual runtime retry after deterministic
allocation refusal, not system-wide OOM or Bluetooth radio ingress.

## Controller ownership after task-startup OOM

`tests/ble-hardware/controller-startup-oom.toit` runs on a dedicated board as an
ordinary application container. Each of 12 child containers opens and initializes
VHCI, limits its heap to 64 KiB, then starts task/latch work while exhausting the
heap. The child has no explicit controller cleanup. The parent requires exit 1,
opens a fresh transport, checks an empty fault-free native queue, initializes
the controller, and closes/joins it before starting the next child.

S3 Board1 passes all 12 cycles in `build/ble-controller-startup-oom-002`, with
HRT and interpreter helpers in IRAM enabled, PSRAM disabled. Logs include actual
stack-growth OOM, all ordered ownership/death/recovery records, COMPLETE and deep
sleep. Free native memory across cycles 2–11 is 202104–202136 bytes; the largest
free block is 53248 bytes. These are short-run observations, not a long-term leak
bound. The maintained AWK checker passes and rejects deleted recovery/OOM evidence.

The original two-minute campaign 001 times out after ten completed recoveries
and is retained as a failure. Campaign 002 allows four minutes for the same
12-cycle sequence and substantial serial heap diagnostics. Flash 62665 verifies
and exits zero; monitor 47517 is stopped after terminal deep sleep and exits 1.
Application-only flashing preserves NVS and stored programs. No peer, pairing,
scan or advertising is involved, and no dongle is used.

Original ESP32 Board2 subsequently passes the identical snapshot in
`build/ble-controller-startup-oom-003`: all 12 deaths/reopens and terminal cleanup,
HRT on, interpreter helpers in IRAM off. Flash 22744 verifies/exits zero; monitor
12256 stops after deep sleep and exits 1; the serial port is then unowned.
Cycles 2–11 report free native memory 140248–144392 bytes and largest blocks
57344–110592 bytes. There is a roughly 4 KiB step down at cycle seven; its cause
is not established by this short run. This result verifies reopen correctness,
not absence of leaks. Stored bonds remain untouched.

The strengthened verifier requires stack-growth OOM evidence within every
child's ownership/death interval. Both complete target logs pass; removing
stack-growth evidence or a recovery record fails. The earlier S3 checker and
its result remain archived, with the stricter recheck stored in campaign 003.

These tests verify native reclamation after process termination on these two
configurations. They do not make OOM catchable in an arbitrary Toit task, cover
pending peer traffic, or establish the same startup path on Linux.

Follow-up campaign `build/ble-controller-startup-oom-004` adds one detailed heap
report after each recovery. All 12 cycles pass again on original ESP32. The
cycle-seven decrease recurs and is accounted for exactly: free memory falls
144384→140232 bytes (4152 bytes), while the report total rises 104552→108704.
System-process pages grow 12288→16384 bytes; thread/other adds 40 bytes, lwIP adds
8, and allocator overhead adds 8. The parent process stays at 8192 bytes, event
source at 2368/31 allocations, and untagged at 23144/112 allocations. Only the
system and parent processes remain in each post-cleanup report.

This identifies the decrease in the instrumented run as chiefly one additional
system-process heap page. It is consistent with the same-sized step in campaign
003, but that earlier log lacks reports at the exact checkpoint. The reason the
system process retains that page and its longer-run behavior are not established.
This is not evidence for changing BLE queue sizes or a leak-free claim. The
maintained fixture now includes these post-cleanup reports for future diagnoses.
