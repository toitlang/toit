# Cleanup after allocation failure

Priority clarification from the SDK maintainer,2026-09-11: survival after a
reported OOM is best effort and normally a board reset is acceptable. The managed
recovery tests below provide useful scoped evidence, not a general production
requirement. Primitive allocation/GC retry correctness remains mandatory because
GC occurs at primitive boundaries. Existing ownership and cleanup fixes remain.

Three failures reproduced on 2026-09-11 while testing mixed BLE service startup
required changes in BLE, generic service resources, and core collections. The
regressions use real heap exhaustion at a 256 KiB process limit, then release
ballast and verify that resources and surviving data remain usable.

## Central worker startup

`ConnectionSession` registered its RPC resource and retained a shared host before
creating its worker task. A task allocation failure leaked the host reservation.
The old implementation produced `resources=1 released=false` in
`build/ble-central-start-pressure-001/before.log` and exited 255.

Construction now rolls back the reservation and closes the resource if no worker
was created. Reservation release runs before resource removal, so a second
allocation failure during unregistering cannot keep the controller reservation.
No escaping closure or extra per-session rollback field is needed.

`tests/ble-service-central-start-pressure-test.toit` exercises 96 slack levels:
41 fail construction and 55 reach the worker. Every case ultimately leaves no
registered resources and permits a new host reservation. A mixed-role case also
keeps the peripheral alive, performs survivor ATT reads around a failed central
constructor, then establishes and uses a replacement central session. Final
controller counts are one open and one close.

Resource removal itself can still fail while the heap is exhausted. The resource
remains retryable, and this test performs ordinary client resource cleanup after
memory recovers. It does not prove immediate removal under arbitrary exhaustion.

## Service resource removal

`ServiceResource.close` previously cleared its handle and provider before removing
the registry entry. If removal failed, the resource appeared closed, its callback
had not run, and subsequent close calls could not retry. The original cold
pressure case reports `closed=true callbacks=0 registered=1` and exits 255 in
`build/ble-resource-close-pressure-001/before.log`.

Close now unregisters first, then clears the handle and invokes the callback.
Removing the last resource removes its client entry directly. Since Map removal
can delete an entry before an optional shrink fails, unregister checks whether
the entry remains before propagating the failure. Callback failure still leaves
the resource closed; callbacks are not automatically retried.

`tests/services-resource-close-pressure-test.toit` covers cold deletion and 96
shrink-boundary trials, both within one client's resource map and across the
provider's client map. After recovery, repeated close calls invoke each callback
exactly once, remove every registration, and allow a fresh resource to close.

## Map and Set shrinking

Expanding the resource test exposed a core collection bug: shrinking compacted
the existing backing before allocating its replacement index. Allocation failure
left old index positions pointing into moved entries. Iteration still found seven
resources, but lookups could no longer remove them. The failure and old sources
are preserved in `build/ble-resource-close-pressure-001/shrink-before.log` and
`collections-before.toit`.

Shrinking now builds separate backing and a fresh index, restoring the previous
backing, index and index capacity bookkeeping if rebuilding fails. The target
removal may already have committed, but surviving entries remain usable. This
temporarily retains both old and new storage, increasing peak memory during a
successful shrink; failure leaves the larger usable representation available.

`tests/set-map-shrink-pressure-test.toit` covers 48 slack levels for each of Map
and Set. It verifies membership and values after failure and GC, followed by
removal retry, insertion and complete removal. Normal builds produce 11 failures
and 37 successful shrinks for each type; optimized builds produce 10 and 38.
Both outcomes are required, without asserting a fixed allocation threshold.

## Validation and remaining limits

All three regressions pass normally, under ASan/LSan outside the sandbox, and with
`-O2`. Evidence is in `build/ble-central-start-pressure-001`,
`build/ble-resource-close-pressure-001`, and
`build/ble-collection-shrink-pressure-001`. Expected OOM diagnostics are retained.

All 1,141 tests selected by `^tests/` have passed across the broad run and its
targeted reruns. The first sandbox run passed 1,093; network permissions, missing
generated assets, and an outdated golden trace explained the remaining failures.
After building `build_test_assets`, the outside-sandbox reruns left only UDP
multicast. That test passed in an isolated network namespace with the loopback
route specified by CI. The machine's multicast route points to its physical
network interface and was not changed. This is aggregate evidence, not a single
uninterrupted 1,141-test run. All 166 BLE/crypto tests passed in the initial run.

The frozen 24-hour service soak predates these fixes. Scripted heap-pressure
coverage does not establish arbitrary hardware OOM, process-death cleanup under
exhaustion, power-loss durability, or general RF reliability. Authenticated radio
regression of freshly compiled applications and system containers passes in
`build/ble-mixed-authenticated-death-radio-003`: four S3 receive credits,
authenticated pending-request provider death and replacement, unchanged bonds,
400 radio and 200 local reads, GC, expired old handles, one replacement controller
lifetime, and verified board/adapter cleanup. This run does not inject hardware
allocation failure.

The shared tests now accept heap and ballast limits for device use. An optimized
S3 application passes290 cases at64KiB in
`build/ble-service-cleanup-pressure-device-003`:96 collection,97 resource,96 central
startup and one mixed survivor/replacement case. Each collection sweep has10
failures/38 successes; central startup has29/67. All values, callbacks, registrations,
reservation reuse and final controller counts pass. Runner exit0,187-second
capture, final deep sleep and free serial port are verified. The controller is
scripted, so this adds device VM/heap evidence without claiming radio traffic
under exhaustion. Earlier device attempts001/002 remain failed/incomplete.

A separate probe records a public service-client close that cannot retry after
OOM, leaving a resource registered (`build/ble-service-client-close-pressure-001`).
That remains optional hardening under the maintainer's clarified priority; no
default failing test or production change was added for it.
