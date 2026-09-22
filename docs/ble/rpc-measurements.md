# Service request RPC measurements and ownership

## Request ownership allocation cost (2026-09-22)

`build/ble-ownership-cost-001` compares isolated library copies differing only
in the connection-address and raw ATT request ownership fixes. The same compiler,
VM and benchmark run before/after/after/before; both repetitions give identical
allocation totals. The optional `tests/ble-benchmarks/att-requests.toit` sends
100 warmup and1000 measured acknowledged raw writes at each value size, with
MTU517,27-byte ACL fragments and one transmit credit. Every fragment and response
is checked; the input remains intact across full GC.

| Value bytes | Before: allocated bytes /1000 requests | After | Extra bytes /request |
| --- | ---: | ---: | ---: |
| 20 | 784,424 | 824,424 | 40 |
| 512 | 8,631,936 | 9,167,936 | 536 |

The copied ATT PDU includes its three-byte write header. These64-bit host totals
include simulated-peer work and per-fragment GC instrumentation. They measure
allocation traffic, not retained heap, minimum RAM, RPC cost, throughput or ESP32
cost. Connection setup precedes the measurement, so its new address copy is not
included. No radio is used and installed board images are unchanged.

The existing notification benchmark also passes all four runs, with identical
7,752,632-byte totals per1000 deliveries. Its measured service reads use the
private owned long-read path, which did not gain the new public-boundary copy.
That result must not be interpreted as zero cost for raw ATT requests. Prior
device measurements below retain their original frozen-code scope.

## Notification provider copy reduction (2026-09-10)

The central service now returns ATT's owned payload view directly. The native
message encoder copies ByteArraySlice contents into RPC messages, so the previous
intermediate `stream.receive.copy` was redundant. The receiving application's
owned-value contract is unchanged; a failed RPC receive remains uncertain.

The optional `tests/ble-benchmarks/notifications.toit` benchmark measures1000
512-byte deliveries after100 warmups through direct provider-session calls with
a simulated HCI peer. Process-accounted allocation falls from8,280,632 to7,752,632
bytes in the before/after runs:528 fewer bytes per delivery on this host. Exact
payloads, a retained sample across GC and cleanup pass. The optimized ASan/LSan
run reports the same count. These totals include peer/benchmark work and do not
measure RPC serialization, radio throughput, latency or ESP32 memory savings.

A separate real-RPC test now uses512-byte values and constrained client heaps.
Its corrected64-trial sweep observes42 allocation failures and22 exact deliveries;
all clients exit the subscription and disconnect before reporting provider cleanup.
Normal and ASan/LSan pass. The narrower initial sweep's failed coverage assertion
is retained. Evidence: `build/ble-notification-copy-001`.

The same frozen benchmark snapshots also complete on non-PSRAM ESP32-S3 with
HRT/helper IRAM enabled (`build/ble-notification-copy-device-001`). Across1000
measured deliveries, process-accounted allocation is5,888,320 bytes before and
5,368,320 after:520 fewer bytes per512-byte value on this32-bit target. Both
images pass exact values, retained contents after GC and normal shutdown.
This single sequential pair uses the same native firmware and simulated HCI;
it measures allocation traffic, not minimum heap size, RPC latency or on-air
throughput. The host's528-byte figure should not be substituted for this result.

## Native GC timing scope

The host runtime's existing `-Xtracegc` option reports timed collector phases
from `TwoSpaceHeap::collect_new_space` and `collect_old_space`. Scavenge timing
ends before a possible old-generation collection; mark/sweep timing covers
`perform_garbage_collection`, including compaction when reported. These elapsed
intervals exclude acquiring the outer object-heap lock and do not measure the
complete application pause or time waiting to be scheduled. They can include
OS preemption. Printing each record also perturbs subsequent execution.

`build/ble-rpc-gc-trace-host-001` runs the same six-case snapshot with that option.
All payload/terminal checks pass, actual VM exit zero. The following samples are
from the ordinary RPC cases; full results for direct and copied-value modes are
archived in `phases.json`.

| Bytes | Native phase | Samples | Median µs | p95 µs | Maximum µs |
| --- | --- | ---: | ---: | ---: | ---: |
| 20 | Scavenge | 241 | 8 | 13 | 29 |
| 20 | Mark/sweep with compaction | 14 | 23 | 54 | 54 |
| 512 | Scavenge | 513 | 8 | 14 | 28 |
| 512 | Mark/sweep | 23 | 6 | 9 | 11 |
| 512 | Mark/sweep with compaction | 14 | 24 | 44 | 44 |

Samples include every process's records between each case's START/END markers,
including warmup, setup and explicit reporting GCs. They are not limited to the
1,000-cycle measurement window, so counts must not be compared directly with
the benchmark's process-counter deltas. This host-only traced run establishes
collector-phase measurements, not ESP32 pause distributions or a real-time
latency bound. The untraced cycle tables below remain the latency evidence.

## Current ESP32-S3 measurement

`build/ble-rpc-device-current-001` runs the current request benchmark on PSRAM
S3 Board1 with PSRAM disabled and the opt-in HRT clock. One snapshot runs six
cases: direct, RPC and RPC with received-value copies at 20 and 512 bytes.
Each case has 100 warmup cycles and 1,000 measured read/validated-write/write-hook
cycles at MTU 517, with exact payload checks. The RPC application runs in a
separate process. The fixture opens no controller or radio transport.

| Bytes | Mode | Median cycle µs | p95 cycle µs | Process-accounted allocation B/cycle |
| --- | --- | ---: | ---: | ---: |
| 20 | Direct | 419 | 1,012 | 553.620 |
| 20 | RPC | 8,083 | 9,165 | 3,489.788 |
| 20 | RPC with received copies | 8,128 | 9,340 | 3,537.676 |
| 512 | Direct | 1,787 | 2,294 | 5,966.836 |
| 512 | RPC | 11,304 | 12,761 | 12,404.280 |
| 512 | RPC with received copies | 11,683 | 13,033 | 13,439.840 |

RPC allocation sums the provider and application process counters. It includes
registered external allocations and benchmark work, and is not a count of
payload copies. This single sequential run shows substantial service overhead;
it is not a controlled comparison across boot order, a radio throughput result,
a GC pause distribution, or a production load limit. The direct cases share the
wrapper process; each RPC case spawns a fresh application process. Post-GC state
includes sample storage and benchmark/runtime bookkeeping.

All six cases complete, with normal deep sleep. Application-only flashing
preserves NVS/program storage and verifies with exit zero. The serial observer
is stopped after completion and exits 1 from SIGINT; this is not a firmware
failure. The same snapshot passes on the host. Archived raw logs, structured
results, snapshots/configuration and hashes accompany a temporary offline
checker that rejects a truncated run and a missing client result. The checker
adds no SDK/default-test dependency. Other ESP32 targets and repeated controlled
measurements remain separate work.

## Current original ESP32 measurement

`build/ble-rpc-device-current-002` repeats the same six cases with the identical
snapshot on ESP32 Board2 (ESP32-D0WD revision 1.0, 240 MHz, opt-in HRT clock).
All cases pass their payload checks and complete with normal deep sleep.

| Bytes | Mode | Median cycle µs | p95 cycle µs | Process-accounted allocation B/cycle |
| --- | --- | ---: | ---: | ---: |
| 20 | Direct | 848 | 1,534 | 553.620 |
| 20 | RPC | 22,069 | 23,150 | 3,487.676 |
| 20 | RPC with received copies | 22,420 | 23,777 | 3,556.132 |
| 512 | Direct | 2,422 | 2,640 | 5,964.064 |
| 512 | RPC | 25,695 | 26,879 | 12,434.876 |
| 512 | RPC with received copies | 26,163 | 27,946 | 13,484.336 |

The service path is substantially slower on this board in these single runs,
despite similar process-accounted allocation. These measurements do not isolate
the cause: target/runtime differences, scheduling and repeated controlled runs
need investigation before attributing the gap to a specific implementation.
Each cycle contains three application callbacks and their payload checks, not
one on-air operation. All scope/counter qualifications above also apply here.

Application-only flash verifies with exit zero and preserves stored partitions.
The observer is stopped after terminal completion/deep sleep and exits 1 from
SIGINT. Board2 is idle in the benchmark image. Raw and structured results,
configuration, exact snapshot and image hashes are archived with the run.

### Interpreter helper option comparison

Configuration review found `TOIT_INTERPRETER_HELPERS_IN_IRAM=y` on the S3 and
disabled on the original ESP32. Both use 240 MHz, size optimization, dual cores,
100 Hz FreeRTOS ticks and the HRT clock. The option also controls the native
`INTRINSIC_HASH_FIND` path in `src/interpreter_run.cc`; disabling it falls back
to Toit lookup code. It is therefore not a pure code-placement comparison.
The original ESP32's linked IRAM is already nearly full.

An isolated S3 build changes only that SDK configuration option. The same board
and exact benchmark snapshot complete all six cases in
`build/ble-rpc-helper-comparison-001`. The linked native hash-find symbol is
present in the baseline and absent in the comparison.

| Bytes | Mode | Helpers on median µs | Helpers off median µs |
| --- | --- | ---: | ---: |
| 20 | Direct | 419 | 425 |
| 20 | RPC | 8,083 | 8,768 |
| 20 | RPC with received copies | 8,128 | 8,837 |
| 512 | Direct | 1,787 | 1,826 |
| 512 | RPC | 11,304 | 12,364 |
| 512 | RPC with received copies | 11,683 | 12,732 |

The disabled-option S3 measurements remain well below the original ESP32's
22,069/25,695 µs ordinary RPC medians. This comparison does not account for the
full observed board gap. It remains a single sequential configuration comparison,
not a repeated causal decomposition. No default option or runtime fast path was
changed. The S3 is idle in this comparison image; the ordinary build is preserved.

## Historical service 0.17 measurement

Measured the current request bridge using the separately built SDK with its
updated embedded system boot. Each mode/size warms up for 100 cycles and then
validates 1,000 read/validated-write/write-callback cycles at MTU 517. The radio
soak ran concurrently, so these single-run timing samples are not controlled
performance guarantees or ESP32 measurements.

Source inspection found that RPC copies internal arrays larger than 128 bytes
into external storage and transfers already external arrays by neutering the
sender. A new service regression reproduced set-value emptying an externally
backed 20-byte caller array. The BLE client now snapshots outgoing byte arrays
for advertising, scanning filters, connection addresses, values, UUIDs, writes
and read replies. This fixes caller ownership without changing the wire API.
Returned large values can still be external; owned does not mean compactable.
A subsequent guard rejects fixed protocol oversizes before making ownership
copies or submitting RPC: 31-byte advertising data, 6-byte addresses, 16-byte
UUIDs and 512-byte values. The provider still validates exact forms and smaller
configured/negotiated limits. The timing table below predates this guard.

| Value bytes | Direct median cycle us | RPC median cycle us | RPC p95 cycle us | Allocated bytes/cycle, both RPC processes | Provider bytes after GC | Client bytes after GC |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 10 | 251 | 308 | 6136.9 | 21200 | 6512 |
| 20 | 12 | 258 | 307 | 6547.8 | 21224 | 6512 |
| 128 | 13 | 255 | 310 | 8439.4 | 21328 | 6512 |
| 129 | 12 | 259 | 308 | 8591.2 | 21336 | 6512 |
| 244 | 13 | 250 | 298 | 10611.7 | 21448 | 6512 |
| 512 | 13 | 260 | 320 | 15405.7 | 21712 | 6512 |

The pre-fix run is in build/ble-rpc-benchmark-017; final snapshots/logs/results
are in build/ble-rpc-benchmark-017-owned. Client allocation increases by about
560 bytes/cycle at 512 bytes in this workload. It is not a measurement of all
outgoing methods or an exact total of payload copies. Keeping caller buffers
intact is required correctness; no throughput tradeoff waives that contract.

**Counter correction, including the historical figures below:**
`ObjectHeap::bytes_allocated` includes `external_memory_`, and
`total_bytes_allocated` includes `total_external_memory_` (src/heap.h).
The process counters therefore include managed object-heap bytes and registered
external allocations. They exclude unregistered native allocation and do not
separate compactable from external payload bytes. Earlier descriptions calling
these managed-only figures were inaccurate. Post-GC values also include the
benchmark's timing list and other state; they are not pure protocol/RPC RAM.

The source-level RPC path for an internal array copies payload bytes into the
message buffer and then into the receiver's internal array at sizes up to 128.
Above 128, it copies bytes into a malloc-backed array which the receiver adopts.
This explains the ownership/storage distinction, but does not count all message
framing, protocol snapshots, buffer allocation, or retransmission copies.
No runtime IPC payload-copy instrumentation or ESP32 pause distribution is
claimed by this benchmark. Those measurement gates remain open.

# Historical service 0.14 request RPC measurement

Extended `tests/ble-benchmarks/requests.toit` to accept an optional value size
from 0 through 512 bytes (default 20). The existing benchmark compares the same
dynamic read, validated write and accepted-write callback through direct scoped
blocks or through a real service connection to a separately spawned application
process. The attribute server is driven locally at MTU 517; no HCI transport or
radio participates. This measures the request bridge, not every service API.

Each case warms up for 100 cycles, then measures 1000 cycles. Cases ran
sequentially on the development Linux host. These are single-run measurements,
not controlled performance guarantees. The earlier 20-byte measurements in the
progress log remain historical; current runs explicitly use MTU 517.

| Value bytes | Direct median cycle us | RPC median cycle us | RPC p95 cycle us | RPC allocated bytes/cycle, both processes | Provider live bytes after GC | Client live bytes after GC |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 29 | 339 | 465 | 5835.2 | 20904 | 6184 |
| 20 | 25 | 331 | 437 | 6271.3 | 20928 | 6184 |
| 244 | 10 | 329 | 438 | 10560.9 | 21152 | 6184 |
| 512 | 18 | 373 | 541 | 15611.2 | 21472 | 6184 |

The allocation figures count all managed object-heap allocation during the
benchmark, including protocol records, RPC envelopes, payload generation and
correctness checks. They are not a count of payload copies or native allocation.
Post-GC values include benchmark state; the provider retains 1000 timing sample
slots. Absolute provider/client heap sizes cannot be compared as pure RPC cost.
A single post-GC sample does not prove absence of growth over a long run.

The RPC median is hundreds of microseconds per three-operation cycle on this
host. Allocation churn rises materially with payload size despite modest final
live state. This makes RPC overhead a real optimization/measurement target;
compacting GC does not eliminate serialization, allocation or scheduling costs.
Do not infer ESP32 radio throughput or connection capacity from these figures.
No implementation tradeoff or production threshold was selected from this run.

Reproduce each mode and size:

```sh
build/host/sdk/bin/toit run --project-root tests \
  tests/ble-benchmarks/requests.toit -- rpc 1000 512
```

Replace rpc with direct and 512 with 0, 20 or 244. The final raw logs and JSON
are in `build/ble-rpc-benchmark-014-live/`. The first measurement without client
post-GC reporting is preserved in `build/ble-rpc-benchmark-014/` and is not the
source of this table. Every measured cycle validates payloads and write results.
The empty case validates callback sequencing/count, not a payload sequence field.

Remaining gates include exact payload-copy accounting, representative ESP32
measurements, allocation/GC pause distributions, load limits, multiple clients
and quotas, longer-run memory trends, and radio throughput/latency under pressure.


## Removing redundant internal write snapshots

A subsequent ownership review removed two copies from each accepted short
Write Request/Write Command. The ingress payload remains copied before any
validator runs; validators receive a separate copy. Database value access and
accepted-write hook delivery still return copies. Internally, the database and
pending accepted-write record can therefore share the private snapshot. Database
updates replace the stored array, preserving an older pending write record.
Prepared writes already used this internal sharing pattern.

The unchanged 1000-cycle workload was rerun at 20 and 512 bytes. Direct managed
allocation fell by exactly 80 and 1056 bytes/cycle, respectively. RPC provider
allocation fell by 75.2 and 1052.072 bytes/cycle; small bookkeeping differences
prevent interpreting those figures as exact copy counts. The application RPC
boundary still copies data, and no latency guarantee follows from these runs.
Raw results are in build/ble-rpc-benchmark-014-owned; the table above remains the
pre-optimization baseline. This removes two known local copies, not all RPC
serialization or allocation overhead.

The new ble-write-ownership-test exercises source and validator mutation, public
read-snapshot mutation, database replacement before callback delivery, callback
mutation, one-shot delivery and GC for both short writes and commands. All nine
selected write/server/service tests pass after the optimization.

## Copying received RPC values into internal storage

The `requests.toit rpc-copy` benchmark mode copies each incoming validation and
accepted-write payload before inspecting it. This is an application-side
experiment; the BLE client receive policy is unchanged. Compared with `rpc`,
there are two additional ByteArray copies per cycle. Both modes use the same
100 warmup and 1,000 measured cycles with payload validation.

| Value bytes | Additional client allocation per cycle |
| --- | ---: |
| 20 | 80.064 B |
| 128 | 291.528 B |
| 129 | 303.864 B |
| 244 | 528 B |
| 512 | 1,056 B |

These are process-accounted allocation differences, including bookkeeping, not
an isolated count of payload copies. Raw samples are in
build/ble-rpc-receive-copy-checks/results.json and per-run logs. Latencies varied
substantially during the concurrent radio soak (including apparent speedups
when copying); these single runs do not establish the timing effect. This
workload does not retain the copied values long term and therefore cannot
measure fragmentation improvements or realistic retention savings.

A separate storage probe in ble-service-rpc-ownership-test uses actual service
RPC results at 20, 128, 129 and 512 bytes. Sending the received 129/512-byte value
through raw RPC neuters its source, demonstrating external backing. Sending its
`.copy` does not neuter the copy, and the retained bytes remain valid across GC.
This agrees with MessageDecoder adopting external payloads above the inline
threshold and Process::allocate_byte_array using internal storage for arrays
that fit its heap allocation limit. ByteArray.copy allocates a normal array.
The probe passes on the host SDK; it is not an ESP32 fragmentation measurement.

Applications can copy retained values when compactable storage is useful.
Changing the default receive path still needs representative ESP32 retained-value
and native-fragmentation measurements. Copying adds allocation and does not
remove the external transport buffer before GC reclaims it; it can temporarily
increase memory pressure. Small results already arrive internally backed in
this fixture, so copying every result also adds work where no conversion is
needed. No new VM primitive or receive-policy switch was introduced.

## ESP32 retained-value experiment

`tests/ble-benchmarks/retained-values.toit <raw|copy>` uses an actual service RPC
provider in a separate process, without opening its controller transport. It
fills 64 slots with mixed 20/128/129/244/512-byte values, replaces all slots four
times, releases alternate slots, then releases the remainder. Every retained
payload is checked around full GC. Each mode receives 320 values and emits eight
phase records plus `BLE_RETAINED_VALUES COMPLETE ... validated=true`.

Both modes pass on the host. At the final churn checkpoint, process-accounted
allocation is 23,089 B for raw values and 22,608 B for copies; after releasing all
values, both report 4,296 B. These include runtime bookkeeping. The host's system
free/largest counters are sentinel values and cannot measure native fragmentation.
Also, process stats index 2 includes registered external allocations in addition
to reserved object-heap storage (`ObjectHeap::bytes_reserved`); it does not isolate
the compactable heap. Earlier documentation describing it as heap-only was wrong.

Both ESP32 modes now pass from fresh boots on spare Board2, with application-only
flashing preserving stored partitions. Current images, source, logs, validated
phase records and hashes are in `build/ble-retained-values-esp32-001`. All eight
phases, retained counts, increasing compacting-GC counts and terminal 320-value
validation pass. Both monitors exit 124 after completion and normal deep sleep.

| Measurement (bytes) | Raw RPC values | Copied values |
| --- | ---: | ---: |
| Process allocation at final churn | 18,393 | 18,120 |
| Process allocation after release | 2,312 | 2,312 |
| Native free after release | 131,520 | 131,536 |
| Largest native free block after release | 90,112 | 94,208 |
| Cumulative allocation at completion | 528,764 | 601,048 |

Both start with 130,976 bytes native free and a 110,592-byte largest free block.
Copies leave a slightly larger contiguous block in this run, at the cost of
additional allocation. This bounded experiment supports byte preservation and
post-release recovery; it does not establish a general fragmentation advantage
or measure radio load. Process counters include registered external allocations.
