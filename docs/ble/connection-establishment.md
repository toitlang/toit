# Investigating disconnects during initial discovery

Current result (2026-09-19): `build/ble-reconnect-current-s3-002` also fails on
the current managed host, including the bounded-accept failure-wakeup fix.
Three warmups and 15 measured cycles complete (180 exact echoes), then the next
service discovery fails with reason `0x3e`, 248063 microseconds after `connect`
returned. The S3 never records that next connection and times out in accept.
Resource samples stay bounded; host/checker exit1, board deep sleep and adapter/
serial/lease restoration are verified. This run uses the same adapter MAC as001
(now hci0), but USB policy is auto instead of on. Both failures remain evidence;
neither establishes a host scheduling, allocation, USB, or RF root cause.

The following diagnostic `build/ble-reconnect-idle-s3-001` reuses byte-identical
S3 firmware without flashing. Linux delays one second before constructing ATT,
counts all transport-accepted outbound ACL, and dumps its bounded public event
ring after shutdown. A failure during the wait with `acl-before-att=0` would
rule out early outbound Linux ACL for that attempt. Nonzero counts can include
L2CAP signaling. A passing delayed run would not justify a production delay or
replace the plain reconnect acceptance gate. The run stops on its first failure.
This run is now terminal:3 warmups +48 measured cycles (510 echoes), then
attempt51 reports `acl-before-att=0 att-created=false` and reason0x3e.
Controller creation/disconnect records are253971us apart. The one-second delay
therefore did not prevent this failure, and early outbound Linux ACL/ATT cannot
be its trigger. Controller LL traffic, RF and other host/controller timing remain
possible causes; no over-the-air capture identifies which. The S3 again never
records the next connection. Host/checker reject the1000-cycle gate; board deep
sleep and adapter/serial/lease restoration pass. Sources/artifacts are unchanged.
Software probes verify hook ordering before ATT receiver ownership and preserve
an injected reason0x3e with zero outbound ACL. Normal/optimized probes and three
focused connection-event/reconnect CTests pass; these do not identify the RF
failure. The phone is withdrawn and is not part of this diagnostic.


The current-managed-code plain S3 Board1/hci3 run in
`build/ble-reconnect-current-s3-001` failed, observed2026-09-11 23:15UTC.
It completed three warmups and77 measured cycles (800 exact echoes), then
reported `RECONNECT_FAILURE cycle=80 handle=16 interval=36 elapsed-us=255979
ended=true reason=62 cause=null` during service discovery. Reason62 is0x3e.
The board completed cycle79 and printed READY, but never CONNECTED for the
failing attempt; it subsequently reported DEADLINE_EXCEEDED and entered deep
sleep. Host/supervisor exit1 and the offline checker rejects the run.
Offline decoding with the exact archived snapshot confirms the exception at
`Central.accept`'s `pending.get`, after the Advertising Enable command returned
successfully. Snapshot UUID6248be62-add7-52b3-ab76-faa947908939 matches the raw
exception; its different envelope container image ID is not a firmware mismatch.
The decoded stack is retained as `exception-decoded.txt` in the campaign.
Memory samples remained bounded: host descriptors9/live at most9632 bytes;
board allocated1432/free206800/largest69632 at its final completed cycle.

This is the first captured controller establishment-failure reason in these
plain campaigns. It supports a failure before peer data-channel establishment,
not an OOM diagnosis; it does not identify the underlying radio/controller or
host-timing cause. No automatic retry or application replay has been added.
The monitor was stopped after deep sleep (exit130), adapter settings match the
saved baseline, USB autosuspend remains off and the serial port is released.
See [board matrix](board-matrix.md) for remaining reservations.

The plain reconnect campaigns failed during `gatt.services` after `connect`
returned, while the ESP32 timed out waiting for its next accepted connection.
An earlier one is `build/ble-reconnect-receive-1000-001`, after 274 measured cycles.
The first plain receive-credit multi-link run has a similar high-level symptom.
Neither log contains enough controller metadata to identify the cause.

The completed diagnostic repeat used the existing fixed-size connection-event
recorder in `tests/ble-hardware/connection-events.toit`. It retains the final
32 connection/disconnection records and formats them only after shutdown.
Do not treat an instrumented pass as an explanation of a plain failure.

The recorder now also selects Reset, Advertising Enable, Create Connection,
Create Connection Cancel and Disconnect commands and their completion/status
events. Kind128 records transport acceptance, with opcode in the handle field
and advertising enable in detail. Kinds14/15 record command complete/status,
with opcode in handle and command credits in detail. Other kinds retain their
connection-event meaning. No packet bodies, peer addresses or keys are retained.
The buffer remains512 bytes/32 records. Times are local to each device.
`reconnect-events-board.toit` runs the same per-cycle server fixture through a
scoped transport factory and dumps only the final controller incarnation, after
the reader is joined. The Linux deferred fixture keeps its final32 records.
Software tests cover filtering, malformed framing, send acceptance/cancellation,
owned metadata and chronological ring wrap; three focused CTests and optimized
recorder execution pass in `build/ble-reconnect-events-s3-001`.

The current plain fixture also reports `RECONNECT_FAILURE` before local client
cleanup. It reads the link's existing termination latch only when it is already
set, reporting the handle, connection interval, elapsed microseconds since
`connect` returned, and either the controller reason or host exception. A live
link reports `ended=false` without waiting for another event. Diagnostic errors
are caught so they cannot replace the exchange failure. The successful path adds
one timestamp and a completion flag per connection; it adds no packet recorder
or retries, but is still a changed fixture, not an identical-timing repeat.

`build/ble-reconnect-failure-diagnostics-001` contains a passing software replay
of a live link, a synthetic remote reason 0x3e, and host closure. It checks that
the original exception survives diagnostic reporting. The synthetic reason is
only a logger check and is not evidence of the hardware failure's cause. The
deferred campaign used its frozen older snapshot and has since completed.

The later plain receive-credit campaign002 passed1000 cycles; this did not
explain the earlier failures. `build/ble-reconnect-write-current-001` also passed:
terminal host/supervisor exit0 and the offline checker verify1000 measured cycles,
three warmups and10030 exchanges. The board completed and entered deep sleep;
adapter restoration was verified separately. The run used failure-only metadata
and no retries. Its frozen image predates later receive-credit, service ownership
and procedure-admission changes, so it does not validate those changes or explain
the earlier intermittent failures. The campaign is complete, with no live handles
or remaining polling schedule.

## Specification distinction to check against captured events

The supplied Core 6.3, Vol 6 Part B §4.5 (page 3150), distinguishes creation of
an ACL connection from establishment. Sending or accepting the connection request
enters the Connection state; establishment requires receipt of a data-channel
packet from the peer, even one with a bad CRC. Section 4.5.2 permits much faster
termination before establishment: an unestablished ACL connection is lost after
six connection events. Vol 1 Part F §2.59 defines error 0x3e for failure to
establish a connection or synchronize.

Vol 4 Part E §7.7.65.1 describes LE Connection Complete as notification of
connection creation. These rules mean a successful connection-created event
alone should not be used to infer that ATT traffic has reached the peer. This
is now supported by the0x3e termination captured in the S3 campaign above.
The255979us delay is approximately six45ms connection intervals, but elapsed
time starts when the managed connect call returns, not at a captured radio event.
It therefore does not establish exact link-layer timing or explain why the
initial data exchange failed.

The next useful evidence is a correlated controller-event history on both peers
around the failed attempt, including advertising enable and connection events.
The current failure-only report supplies the host handle, interval, reason and
elapsed time; it does not capture the peripheral controller's event history.
Keep establishment failure distinct from a host-generated abort before changing
retry policy.
Adapter power restoration proves cleanup, not the cause of the disconnect.

The captured sequence now has a software lifecycle regression in
`ble-hci-test.toit`: ten successful creation events followed by0x3e during
service discovery alternate with ten successful connections on the same handle.
Failed discovery receives no completed-packet credit event before disconnection;
the sole transmit credit must become available to the next lifetime. The checks
also close the old ATT client after handle reuse and require the new link to
remain usable. Four focused CTests, optimized execution and ASan/UBSan/LSan pass
in `build/ble-establishment-replay-001`. No production fix or automatic retry
was needed. This checks host recovery from a synthesized ordering; it does not
establish the actual radio credit-event history or underlying failure cause.

LE Read Remote Features Page 0 (Vol 4 Part E §7.8.21) can request remote features,
but is a separate asynchronous procedure and may use a cached result on the
existing connection. Do not add it as an assumed universal connection barrier
or retry application traffic merely to make the campaign pass. Any proposed
connection-establishment/retry change needs its own deadline, cancellation,
security ownership, disconnect and side-effect tests. A scoped untraced1,000-cycle
pass is now recorded above; unexplained earlier failures remain a release gate.

## 2026-09-19: bounded probes with and without early host data

Later mixed-update campaigns retain correlated controller records from both
boards. In `build/ble-mixed-update-exit-radio-002` and
`build/ble-mixed-update-win-radio-001`, S3 reports successful connection creation
followed by reason0x3e; original Board2 records successful advertising enable
but no connection event before its accept deadline. This locates the captured
failure before a peer connection event, without identifying its cause.

Six direct-host attempts in `build/ble-establishment-idle-001` hold a link for
one second with zero host ACL submissions and disconnect normally. A following
comparison keeps the mixed service, separate client and provider full-GC task:
four one-second-delay attempts in `build/ble-establishment-service-delayed-001`
and four immediate attempts in `build/ble-establishment-service-immediate-001`
each complete 100 exact reads with retained values across GC. Complete records
and cleanup pass. The first accepted ACL follows Connection Complete by
1,007,383–1,007,454 us versus6,953–7,008 us, measured within the provider clock.
Both cohorts use identical client and peer snapshots and one attempt per boot.

These probes capture no establishment failure. They do not exclude early ATT
as a contributor to earlier failures or establish that adding a delay helps.
They also do not recreate the full multiclient workload or supply a reliability
estimate. No production delay, retry or connection barrier was introduced.
