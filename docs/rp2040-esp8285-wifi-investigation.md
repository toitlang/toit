# RP2040 ESP8285 Wi-Fi investigation handoff

Current hardware state: Pico smoke 455 PASS on the exact W-2023 distribution
recovery loader; helper runs the plain native allocation-GC fix and ordinary
Wi-Fi fixture; the modem retains AT 2.2.2 +TOITUDP v2. No hardware test is running.
Local RP2040 and ESP8285 support validation is complete within the documented
scope. The user has authorized all RP2040 and ESP8285 firmware changes; no
firmware approval is pending.

The recovery follow-up reproduced two loader bugs. The old loader dropped
protocol replies when its 1 ms stdout timeout expired: only 116 of 512 queued
`hello` replies survived a read pause, including a truncated reply merged into
a heartbeat. Closing USB after an acknowledged `begin` also left `receiving`
true forever and suppressed discovery heartbeats. After 12 seconds there was
no announcement, although explicit `hello` proved the loader was alive.
Neither reproduction sent image data or a commit.

The fixes wait for TX space with a five-second bound and watchdog feeding,
and cancel a session on disconnect or ten seconds of command inactivity,
clearing partial command framing. A stale queued READY additionally exposed an
uploader handshake bug; the new regression fails before the host fix and all
11 uploader scenarios pass. A lost commit acknowledgement remains possible if
the transport fails; the committed update is durable and later discovery
reports the installed image.

**The fixed loader is installed and tested at its actual boot address.** The
approved candidate passed readback, all 512 replies after a 1.5-second read
pause, discovery after disconnect in 0.589 seconds, and partial-command expiry
in 10 seconds. Five further uploads exercised application exceptions and idle
with USB open and closed, restoring smoke 444.

The distribution build uses size optimization, so it was installed and tested
separately. Its SHA-256 is
`191cfc5d7c37e17206f174d5a8ccbbcf11c40f7a403e398638c5c7c28ee22bd9`.
Both installations saved fresh full-flash backups and verified every UF2
payload and every byte outside the first 64 KiB. The distribution loader
passed the same 512-reply test, disconnected-session discovery in 0.584 seconds,
partial-command expiry in 10.001 seconds, and full upload/smoke restoration.
All three board bundles were refreshed and passed envelope and standalone
uploader tests. The installed W-2023 loader and hardware-tested uploader match
their bundled counterparts exactly.

Final normal-logging application 454 verified all six binary TCP and six UDP
payloads, deliberately reached the expected receive deadline, and recovered
through USB after 30 seconds with the port closed. Smoke 455 passed. A traced
run also passed with acknowledged modem cleanup (451 → 452).

One initial attempt using archived application 448 failed with AT `ERROR`
before any payload passed; it did not reach the required deadline marker and
is retained as a failure. Native queries confirmed the expected AT firmware,
UDP extension and Wi-Fi connection. Native initialization and TCP open/close
then passed. No modem reset or firmware change was made. The exact cause of
that initial error was not established; the later passes do not claim to fix it.
Automatic recovery from arbitrary interrupted AT payloads is still not
provided: the interface fails closed and requires a synchronized transport
before reconnect.

Evidence:

- `build/rp2040-recovery-idle/loader-backpressure/validation.json`
- `build/rp2040-recovery-idle/installed-loader-idle/events.jsonl`
- `build/rp2040-recovery-idle/distribution-modem-final/validation.json`
- `build/rp2040-recovery-idle/distribution-modem-diagnostic/`
- `build/rp2040-recovery-idle/final-bundles/results.json`

The historical USB incidents lacked enough tracing to attribute them
individually. The newly reproduced loader mechanisms and fixes are established
independently. Older results below retain their original scope and chronology.

Sustained USB stress also passes (application 429 → smoke 430): 16,891,904
binary input bytes verified while emitting acknowledgements, 512 CDC baud
changes, and 58,930 GC cycles over 850.5 seconds. After 30 seconds with the port
closed, recovery answered in 1.722 seconds and smoke restoration passed. The
fixture and runner are `tests/hw/rp2040/usb-stress.toit` and `usb-stress.py`;
the fixture is included in CI source analysis. Evidence:
`build/rp2040-recovery-idle/usb-stress/validation.json`. This workload does not
exercise runtime autosuspend, deliberately blocked host reads, or concurrent
flash writes. It adds coverage but establishes no USB fix.

The traced uploader passed hardware acceptance (427 → 428): recovery identity
verified after 838 ms, installed image verified after 19.131 seconds, then
ordinary VM smoke PASS. All ten native uploader PTY scenarios pass, including
missing READY and missing block acknowledgement with unrelated heartbeats.
Evidence: `build/rp2040-recovery-idle/uploader-trace/validation.json`. This
validates the diagnostic path; it does not establish a USB fix.

USB source audit: the old logs describe two distinct failure stages.
Application 343's restore reported `serial response timed out`, which the
then-current native uploader could only report after its recovery handshake.
The later bridge installation reported `recovery unavailable on the selected
serial port`, before completing that handshake. Neither log records enough
detail to attribute the failure to the VM, loader, or host USB transport.
The uploader now has optional `--verbose` timestamps for handshake progress,
block transfers and reboot verification; `recovery-idle.py` enables these and
preserves the first failure without resetting hardware.

The RP2040 E15 USB workaround is already enabled in both VM and recovery-loader
compile commands (`PICO_RP2040_USB_DEVICE_UFRAME_FIX=1`). An upstream
[SDK issue](https://github.com/raspberrypi/pico-sdk/issues/3201) reports that
`getchar_timeout_us(0)` may wait on the USB stdio mutex for the default second;
our pinned SDK has that code too. That report does not establish our failure's
cause. Our dispatcher calls it outside a primitive, and the boot task feeds an
eight-second watchdog independently. The local FreeRTOS port distinguishes
task/IRQ mutex owners and includes the corrected synchronization wakeup path.
No speculative SDK or loader change has been made.

The retained kernel journal adds one constraint: no Pico disconnect was logged
between 15:52:11 and 15:59:15 on October 6, spanning the 15:55–15:56 bridge-upload
and control-probe failures. The selected journal interval has no reported USB
transfer error or over-current event. This does not distinguish a device-side
stall from a host control-path problem. Evidence:
`build/rp2040-recovery-idle/usb-stress/historical-kernel.log` and its summary.
The earlier idle runners recorded host USB power control `on`, runtime status
`active`; they did not exercise runtime autosuspend.

The current-adapter USB recovery regression passed (425 → 426 → 427). It
verified all six binary TCP and six UDP payloads, deliberately timed out a UDP
receive, checked the exact deadline marker, and recovered through ordinary USB
after three minutes with the port closed. Recovery after the initial ordinary
three-minute idle also passed. Evidence:
`build/rp2040-recovery-idle/modem-timeout/validation.json` and `run-180s/` beside
it. This run preceded the independently reproduced loader defects and fixes
described above; by itself it added coverage and did not establish a USB fix. Dynamic OTA is now verified with plain helper
firmware, as detailed below.

USB follow-up: archived adapter application 423 restored smoke 424 successfully,
but decoding its exception showed `ESP_AT_UNSUPPORTED_FIRMWARE`. The archived
image rejects the current modem before traffic, so this is **not** a replay of
the historical post-traffic timeout. Keep that distinction when assessing USB
coverage. Evidence: `build/rp2040-recovery-idle/replay-adapter-failure-result.json`.
A new `tests/hw/rp2040/modem/recovery-timeout.toit` fixture uses the current
adapter, verifies binary traffic, deliberately times out a UDP receive, and
requires the matching marker before its final exception. The existing idle
runner supports this marker and a workload deadline; its three-minute
closed-port run passed as recorded above.

**Latest acceptance result, October 6: dynamic-compression OTA passes with
plain helper firmware and no diagnostic logging.** Application 420 rejected
the truncated body and complete corrupt 606,212-byte image (110.618 seconds),
then downloaded the valid image (111.063 seconds), booted target 421 and verified
its SHA-256. Pico smoke 422 and the ordinary helper application restored PASS.
The same fix previously passed with diagnostic notifications exercised (417 →
418). The hardware runner now defaults to dynamic coding so this case remains
part of the ordinary regression; fixed coding is available as a control.

The native fix is in the root networking sources. ESP-IDF's allocation callback
only stores a flag; pending TCP polls deliver the existing Toit GC event. This
covers lwIP timer/window-split allocation failures missed by primitive output
handling. No special per-packet logging, forced GC task or modem changes are
needed. The plain firmware has no diagnostic strings. Removing an overly
strict atomic assertion for ESP32-C3 produced an identical ESP32 binary; the
C3 compiler probe confirms the hook is a store with no calls, while its exchange
runs on the lwIP task. Host VM and ESP32 native builds pass.

Evidence: `build/rp2040-helper-allocation-gc/manifest.json` and
`build/rp2040-w2023-vm/at2-empty-read-fixed/ota-allocation-gc-plain/hardware.log`.
The sibling cellular documentation records the verified result and helper SDK
requirements. Historical intermittent Pico USB recovery loss remains open.
The following notes
are historical investigation states, superseded by this acceptance result.

Current result: full dynamic-compression OTA passes with the revised native
allocation notification (application 417 → target 418; smoke 419 and ordinary
helper restoration PASS). Both full 606,212-byte bodies arrived: corrupt in
109.687 seconds, valid in 111.176 seconds. The changed image booted and verified
its SHA-256. The diagnostic recorded three GC notifications, two with
`tcp_output` returning success; these exercise the new notification path for
allocation failures outside output. This is a diagnostic result; the same
candidate without logging is now being installed for acceptance.

Root `src/event_sources/lwip_esp32.cc/.h` and `src/resources/tcp_esp32.cc/.h`
now contain the revised candidate. The hook only records a flag; pending TCP
polls publish the existing GC event until a Toit task consumes it. No primitive
blocks to perform GC, no private lwIP timer logic is copied, and queued data
is not enqueued again. Evidence and exact source/binary hashes are in
`build/rp2040-helper-allocation-gc/`; OTA logs are in
`build/rp2040-w2023-vm/at2-empty-read-fixed/ota-allocation-gc-diagnostic/`.
The approved modem v2 image and Pico recovery loader remain unchanged.

The entries below describe earlier investigation states; their statements
about candidates not yet installed/adopted are historical.

Application 415 establishes a persist-timer allocation failure: the peer window
is 224 bytes and the unsent head is 1,440 bytes. `tcp_split_unsent_seg` repeatedly
returns `ERR_MEM`, with a largest free block of 1,192 bytes. No packet is
unacknowledged (rtime=-1, rto=3, nrtx=0); the queued pbuf has ref=1. Thus this
run is not blocked by driver-owned packet buffers or a retransmission timer.
The corrupt-image download timed out at 291,232 bytes. Evidence:
`build/rp2040-helper-retransmit-diagnostic/hardware-proxy.log` and
`at2-empty-read-fixed/ota-retransmit-diagnostic/hardware.log`.

A revised **unvalidated** candidate records ESP-IDF allocation failures in a
lock-free atomic flag, then lets pending TCP polls publish the existing Toit GC
event. This includes window-split failures that happen before `tcp_output`.
The allocation callback performs no allocation, logging, or GC. The diagnostic
ELF confirms its code is in IRAM, its flag in DRAM, and its body only stores the
flag. Diagnostic and plain helper builds pass; source and binaries are retained
under `build/rp2040-helper-allocation-gc/`. Root sources still contain the earlier
poll-only candidate; the new candidate has not yet been adopted or validated.

Latest result, October 6: application 413 rejected the truncated image and
received/rejected the entire 606,212-byte corrupt image in 109.567 seconds.
The valid-image transfer then timed out at 291,456 bytes. The helper had
written 296,648 body bytes and was waiting in `write`. Smoke 414 and the
ordinary helper application both restored successfully.

The stalled connection had the candidate poll callback registered (interval 2),
but no poll-GC request or persist split/output failure was reported. Its ACK
remained 726478070, next sequence 726478454, advertised window 384, with one
or more unacknowledged segments and a 1,056-byte unsent head. Largest free
block was 848 bytes. This does **not** validate the poll candidate or establish
which condition prevents retransmission. A follow-up diagnostic records the
retransmission timer and packet-buffer references; no new production fix is
claimed. Evidence: `build/rp2040-helper-persist-diagnostic/hardware-proxy.log`
and `build/rp2040-w2023-vm/at2-empty-read-fixed/ota-persist-diagnostic/hardware.log`.

Poll-candidate result: application 411 still timed out at 291,264/606,212
corrupt-image bytes. The helper reported 296,904 bytes written, phase=write.
No `TCP poll requesting GC` marker fired. The candidate therefore is **not
validated as a fix**; smoke 412 and ordinary helper application restoration
passed. The next diagnostic retains the candidate and reports the actual poll
registration plus persist splitting/output failures after ACK progress stops.
It is being installed from `build/rp2040-helper-persist-diagnostic/`.

Confirmed helper allocation failure, October 6: application 409 is stalled
with the quiet output diagnostic. `tcp_output` repeatedly returns `ERR_MEM`
while the largest free block is 1,064 bytes. The caller addresses resolve to
`tcp_slowtmr` (`tcp.c:1444`) and `tcp_rexmit_rto_commit`, so these failures bypass
the Toit write primitive's GC notification. Evidence and decoded callers are in
`build/rp2040-helper-output-diagnostic/`. This establishes a helper-side cause
for this run, not a proof about every historical stall.

A candidate fix adds an lwIP poll callback while TCP data awaits ACKs. It
retries output and reports `ERR_MEM` through the existing socket GC event;
it removes the callback after all bytes are acknowledged and during teardown.
The root `tcp_esp32.cc/.h` contain this change. Both a diagnostic candidate and
a plain candidate build pass, under `build/rp2040-helper-poll-gc/`; neither has
been installed yet. The reusable helper build now matches the plain candidate
and has no diagnostic logging. Hardware validation is the next step after the
before-case deadline and cleanup.

Timer follow-up in progress: application 407 received the full corrupt image
in 109.7 seconds, then stalled during the valid image. The helper's timer
reports show unchanged TCP sequence numbers, window=2,240, cwnd=1,440,
unacked=0, unsent=1,440 and persist=0. The largest free block was only 1,168
bytes, later 1,360. This is not the earlier small-window/persist state. A
separate diagnostic that reports failures from all `tcp_output` callers,
including retransmission timers, is built but not yet installed under
`build/rp2040-helper-output-diagnostic/`. It has no healthy-traffic logging.

Build provenance correction: the timer image includes the earlier primitive
logging as well. Restoring the source while preserving its old timestamp had
left the compiled diagnostic object in the reusable helper build. **The saved
original image used for actual ordinary firmware restores has no diagnostic
strings.** The reusable build has now been forced to recompile and exactly
matches that original binary SHA-256. The shared ESP-IDF checkout is unchanged;
diagnostic source copies are selected only in the temporary helper build.

Native helper follow-up: application 405 reproduced the dynamic-compression
stall, receiving 291,328/606,212 bytes before the 300-second deadline. The helper
reported 296,904 body bytes written. Its last native TCP report was free=7,304,
largest=4,096, sndbuf=0, queue=4, window=1,280, unacked=0, unsent=1. No
`write-ERR_MEM` or `output-ERR_MEM` report occurred. This instrumentation covers
primitive calls, **not allocations in lwIP timer or Wi-Fi driver paths**, so it
does not rule out memory pressure elsewhere. In the pinned ESP-IDF source,
`components/lwip/lwip/src/core/tcp.c`'s persist-timer path calls
`tcp_split_unsent_seg` and `tcp_output` directly; failures there back off without
passing through our instrumented primitive. Checking that path and the actual
advertised peer window is the next focused diagnostic, not an established root
cause. Both the application failure and USB smoke restore 406 completed; the
ordinary helper app also restored.

Evidence: `build/rp2040-helper-tcp-diagnostic-v2/hardware-proxy.log` and
`build/rp2040-w2023-vm/at2-empty-read-fixed/ota-native-diagnostic/hardware.log`.
The complete same dynamic gzip asset decoded correctly on the host with Toit;
see `gzip-control.toit` and `gzip-control.log` in the diagnostic directory.
The helper fixture now tracks its phase without per-chunk timestamps and prints
that phase only at connection cleanup. This compiles, but was added **after**
application 405; the exact earlier source is retained beside that run's log.
The ordinary native baseline has now been restored and reboot validated,
retaining the rebuilt Jaguar service. The ordinary Wi-Fi helper reports READY
and the Pico is on passing smoke 406; no upload or hardware test is running.
The helper ID is now `c3b4736f-56dd-444b-b71b-846db264c658`. No modem or recovery-loader changes were
made during these follow-ups. The historical intermittent USB loss remains open.

Latest follow-up: the modern adapter passed the final normal-logging stress
and service checks (applications 399/401, smoke restores 400/402). However, the
next full OTA run with dynamic compression timed out after receiving
291,712 of 606,212 corrupt-image bytes in 300 seconds (application 403). Smoke
404 and ordinary helper restoration passed. The helper service refresh has
therefore not established a general large-transfer fix. Its two large fixture
deployments and both restorations succeeded, but that alone does not prove the
previous deployment failures are fixed. Evidence is in
`at2-empty-read-fixed/ota-jaguar-gc-dynamic/` under the VM build directory.
The prepared native TCP diagnostic image is now being installed on the helper
with the rebuilt Jaguar service; no Pico loader or modem firmware is changing.

Helper service follow-up, October 6: normal HTTP application 393 passed both
606,212-byte bodies and hashes after a helper reset (smoke 394). The next OTA
attempt never reached its Pico client: helper deployment and restoration timed
out, while smoke 395 restored. Restarting only the UART proxy did not recover
Jaguar. The installed Jaguar snapshot was dated September 21, before the SDK's
TCP and UDP cached-GC-event corrections. This is a plausible cause of the
helper control failures, not yet a demonstrated explanation for every stall.

The helper service was rebuilt from Jaguar revision
`e90e32eb2110e2bdc7bf3dcb03d379211b7a213c` with its matching alpha.199.16 SDK and
both corrected networking libraries. It was installed with the ordinary native
firmware (no diagnostic instrumentation), rebooted, and validated by the UART
proxy. The new Jaguar ID is `0e03c39a-3d41-463a-938f-d680e4a6d00b`; its name remains
`pico-w-helper`. Build inputs, original snapshot, hashes and update logs are in
`build/rp2040-helper-jaguar-gc/`. Full OTA validation passed under
`build/rp2040-w2023-vm/at2-empty-read-fixed/ota-jaguar-gc/`: application 396
rejected truncated and corrupt images, downloaded the valid 606,212-byte image,
and rebooted into application 397 with a matching SHA-256. The two full bodies
took 109.6 and 111.1 seconds. Smoke 398 and ordinary helper restoration passed.
There was no per-chunk logging or diagnostic observer on the helper. This is
one successful run after the service refresh; it does not prove all previous
stalls had this cause. Older running-process statements below are historical.

Observer control and USB idle follow-up, October 6: HTTP application 387 passed
both 606,212-byte bodies and hashes with zero UART errors when the helper's
memory diagnostic was enabled. **The forced-GC probe never fired.** Adding its
observer task and per-write timestamps changed the result, so this does not
establish a GC fix or normal acceptance. Smoke 388 and the ordinary helper
restored. The three-minute closed-port recovery test then passed all three
uploads, including recovery after an exception (smoke 391). The earlier USB
failure remains unexplained. Evidence is in `at2-empty-read-fixed/http-memory/`
and `build/rp2040-recovery-idle/run-180s-20261006/`.

A normal HTTP repeat did not reach the client: helper deployment and cleanup
each timed out after 90 seconds. Pico smoke 392 restored; Jaguar ping failed.
After stopping the matching UART proxy, an esptool identity/read-only reset
recovered the ESP32, and the replacement proxy (PID 3972263) answered ping.
No firmware was flashed. A fresh normal HTTP control is running under
`at2-empty-read-fixed/http-fresh-helper/`. Native TCP allocation diagnostics are
built under `build/rp2040-helper-tcp-diagnostic-v2/`, **not installed**; its saved
`original.envelope` is the exact pre-diagnostic helper firmware. The helper
source/build tree is being restored to its ordinary baseline after saving the
separate diagnostic artifacts.

Direct HTTP follow-up, October 6: application 385 reproduced the stall without
flash writes or service RPC. The truncated request received all 4,097 bytes and
was rejected; the next corrupt-image request received zero body bytes before
its 180-second deadline, with zero UART errors. The helper accepted that second
GET but did not finish it. This rules out flash writes and service RPC as
necessary triggers. Smoke 386 and the ordinary Wi-Fi helper are restored;
no hardware operation is running. Logs:
`build/rp2040-w2023-vm/at2-empty-read-fixed/http-fixed/`.
The helper-memory diagnostic is built under `at2-empty-read-fixed/http-memory/`
with `--http-only --gzip-strategy fixed --diagnose-helper-memory`, but has not
run. The HTTP fixture now also identifies whether it is waiting for headers or
body bytes. Separately, application 383 passed actual payload cancellation and
deadline isolation plus explicit cleanup at a known byte boundary; arbitrary
automatic resynchronization remains unproven.

Modern OTA follow-up, October 6: both dynamic-gzip application 375 and
fixed-Huffman application 377 rejected the truncated download, then hit the
300-second deadline while reading the full corrupt image. The checksum check
was never reached; no candidate firmware was committed. Smoke restores 376
and 378 and both ordinary-helper restores passed. This modern-adapter failure
therefore is not specific to dynamic Huffman tables. Logs and original fixture
sources are under `build/rp2040-w2023-vm/at2-empty-read-fixed/ota-{dynamic,fixed}/`.
The final matrix remains incomplete. The runner now supports `--http-only` to
isolate the transfer from flash writes and service RPC, with the same image and
compression. An optional `--diagnose-helper-memory` enables the existing GC
probe; that diagnostic changes timing and is not an acceptance configuration.

Modern-adapter TLS follow-up, October 6: the final matrix found another adapter
bug. Applications 365 and 367 failed the first TLS handshake because an
optimistic `CIPRECVDATA` pull received bare `ERROR` while the TCP connection was
still open and awaiting the next handshake message. The prior adapter treated
this as fatal. The corrected adapter treats that precise empty response as
unavailable data while open, retaining notification/poll wakeups; after `CLOSED`
it remains EOF. A new host regression fails before this fix and all four suites
pass afterward on both current and alpha.196 SDKs.
Application 369 passed both authenticated TLS exchanges and wrong-host,
untrusted and expired certificate rejection with normal logging and concurrent
GC; smoke 370 passed. Evidence is in
`build/rp2040-w2023-vm/at2-final/tls-debug/`, `at2-final/host-empty-read/`, and
`at2-empty-read-fixed/tls/`. The earlier modern stress matrix passed application
363, but the final matrix is being repeated with this read fix.

Version-2 installation update, October 6: the user approved the exact candidate
and performed the wireless-BOOT power-cycle. The full pre-update modem backup is
`build/rp2040-w2023-native/esp-at-udp-empty/pre-v2-20261006.bin`, SHA-256
`20dacc8d2518fdd47765a8fe98d81f3a45f10627da3f9951a3603533de0176c1`.
Only the 874,800-byte application at 0x20000 was written; esptool verified it.
Application 348 passed the public adapter's complete binary fixture: TCP/UDP
escape cases, empty UDP send/echo, two queued boundary/metadata/oversize cycles,
and zero UART errors. Smoke restore 349 passed. Evidence:
`build/rp2040-w2023-native/esp-at-udp-empty/hardware-validation.json` and
`build/rp2040-w2023-vm/at2-adapter-binary-v2/hardware.log`.
There is no pending modem-install approval. The first idle/exception USB recovery
regression passed 13 uploads (six deliberate exceptions, 0/1/10-second delays,
serial port open/closed), restoring smoke 362. It did not reproduce or explain
the prior intermittent failure. Evidence: `build/rp2040-recovery-idle/run-20261006/`.
The full production audit remains open.

Latest October 6 follow-up: the cellular adapter has been ported to AT 2.2 with
the UDP extension. It checks firmware capabilities, uses volatile settings,
escapes binary CIPSENDEX sends, and polls passive UDP into bounded queues.
All four host suites pass on the current SDK and minimum alpha.196. Hardware
application 341 passed ordinary TCP and UDP with ephemeral and explicit local
ports; smoke restore 342 passed. Application 343 passed all binary payload cases
on both transports, including literal `+++`, 1,460-byte all-plus/all-backslash
payloads and embedded AT-looking bytes. It then timed out waiting for an empty
UDP echo after an acknowledged CIPSENDEX send. The dedicated CIPSEND length-zero
probe in application 345 returned ERROR; smoke restore 346 passed.

Version 2 of the extension adds `AT+TOITUDPEMPTY=<id>,"<IPv4>",<port>` to send one
empty datagram directly. It builds and passes ASan/UBSan real-socket tests, but
was initially prepared without hardware validation; it is now installed and
passes the adapter fixture as recorded above. Candidate:
`build/rp2040-w2023-native/esp-at-udp-empty/esp-at.bin` (874,800 bytes), SHA-256
`1000b5aafcd21630b907882aa2a9aee36d696241d581416fb4a2dae248e955ab`.
The current adapter accepts receive extension versions 1 and 2; version 1 empty
sends fail explicitly before emitting a command. The new binary fixture covers
empty transmission and adapter-level queued boundaries after the send checks.
The exact firmware build inputs are now retained under `tools/rp2040/esp-at/`.

There is also an unresolved RP2040 recovery failure: the automatic restore after
application 343 timed out, and a later USB recovery request from smoke 346 got
no response despite its earlier PASS. GPIO RUN reset recovered the former;
GP17-low plus RUN recovered the latter. Native bridge application 347 was used for the approved modem flash; the Pico
has since returned to ordinary VM application testing. No recovery loader was replaced. The uploader now identifies the
expected acknowledgement on a transfer timeout; its existing PTY regressions
pass. Do not declare the core target production-ready until this intermittent
USB recovery failure is understood and verified fixed. Evidence is in
`build/rp2040-w2023-vm/at2-adapter-{network,binary}/`, `at2-empty-send/`, and
`build/rp2040-w2023-native/esp-at-udp-empty/`.

Update on 2026-10-06: modern AT **passes escaped binary sends on TCP and UDP**,
including 1,460-byte all-plus and all-backslash payloads with fragmented UART
writes. After the user power-cycled the modem, application 327 passed and smoke
328 was restored. Application 329 then confirmed passive UDP truncation: two
packets totaling 1,916 bytes returned as one 1,460-byte prefix with nothing
remaining. UART errors were zero, reset was acknowledged, and smoke 330 passed.
The approved experimental AT datagram-read extension is now flashed and passes
hardware acceptance: separate queued packets, sender metadata, empty packets,
MTU-sized packets, oversized discard and close/reopen, with zero UART errors.
After an acknowledged AT reset the modem was found in ROM download mode;
starting the installed application through a RAM stub recovered it remotely.
Test cleanup and stale-link setup have been corrected; the matching
cellular stale-link fix passes host regressions on both current and minimum
supported SDKs. Details below distinguish these fixes from modem defects.

Update on 2026-10-02: the approved ESP-AT candidate was flashed and verified;
the modem reports **AT 2.2.2.0 (6cdf453), SDK ff16a35**. Its first acceptance
test still fails on literal `+++` with `SEND Canceled`. After the test's old
filler/reset cleanup, the modem stopped responding, including through the
native bridge. The cause is not established. The user completed a normal
power-cycle, restoring AT responses with zero UART errors. The passive retry
passed single TCP/UDP echoes, but combined two queued UDP datagrams of 97 and
211 bytes into one 308-byte response. The cellular
adapter still targets NONOS and has not been ported to this firmware.

Status as of 2026-10-01: **changed-image Wi-Fi OTA passes with the corrected helper TCP GC handling and fixed-Huffman gzip asset, including a fresh run with the page-aware RP2040 allocator.** The fixture rejected incomplete and corrupt images, installed a different image, and verified its SHA-256 after reboot. The allocator passes twelve container lifecycle cycles, memory pressure and privileged OOM recovery. Broader validation continues. Interrupted AT payload resynchronization remains unresolved. Additional hardware probes confirm that NONOS mistakes literal `+++` payloads for an abort and loses CIPSENDEX escape state across UART receive batches. A lifetime defect was also confirmed in the installed modem firmware, but its responsibility for the earlier HTTP stall has not been established.

This document is for another agent investigating the current local worktrees. It records observations separately from hypotheses. Log paths are relative to `/home/flo/work/opentoit-pi-pico` unless stated otherwise. Most artifacts under `build/` are local and will not accompany a Git checkout.

## Hardware and software

The board is the **RP2040 Pico W-2023 variant with an onboard ESP8285**, not the official CYW43-based Raspberry Pi Pico W, and not the earlier RP2350 test rig.

| Component | Configuration |
| --- | --- |
| RP2040 repository | `/home/flo/work/opentoit-pi-pico`, branch `floitsch/rp2350-pio`, base HEAD `60294e6a`, substantial uncommitted work |
| Modem driver repository | `/home/flo/work/cellular`, referenced by the fixture's local package dependency |
| ESP8285 firmware | Currently AT 2.2.2.0, SDK ff16a35, with experimental `+TOITUDP` extension; earlier adapter/OTA tests used Nano AT 1.7.6.0, SDK 3.0.6-dev. Both use 1 MiB flash, DOUT mode. |
| Modem UART | RP2040 TX GP0, RX GP1; 115200 baud, large buffers |
| Helper ESP32 | Jaguar name `pico-w-helper`; provides isolated Wi-Fi AP, DNS, TCP/UDP echo, TCP burst, TLS, HTTP firmware server |
| Helper network | `200.200.200.1`; SSID `toit-rp2040-test`, password `pico-bringup-test` (public fixture credentials) |
| Compiler | `build/host/sdk/bin/toit`, observed version `v2.0.0-alpha.199.17+floitsch-rp2350-pio.60294e6a` |
| Jaguar executable | `build/pio-jag/jag`; use `JAG_TOIT_REPO_PATH` pointing to this root repository |
| HTTP package | Fixture declares `github.com/toitlang/pkg-http` version `^2.12.0` |

Persistent device paths:

```text
Pico:
/dev/serial/by-id/usb-Raspberry_Pi_Pico_50443405886E0B1C-if00

Helper ESP32:
/dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_d0b0fe3f59faea1181464c185fbcde76-if00-port0
```

Recheck device identity before hardware work. The last recorded helper Jaguar ID was `144b6d5f-0cc7-4271-b44f-c67351c3645e`; reflashing can change it.

The original sixteen inter-board connections are documented in [the RP2040 tools README](../tools/rp2040/README.md). **ESP32 GPIO18 to Pico GP6 is already part of that map.** Earlier requests for five additional jumpers were mistaken. No rewiring is needed for this investigation. GP0/GP1 belong to the onboard modem. The helper's GPIO4 connects to Pico GP17, and GPIO21 connects to RUN.

## Failure and strongest evidence

The OTA fixture starts a separate network-provider container and an HTTP downloader. The helper serves an approximately 588 KiB raw firmware image (602,116 bytes in the recorded runs). Because its program partition cannot hold the image plus helper code, it stores a gzip asset and inflates it while serving an ordinary, uncompressed HTTP body with a Content-Length header.

The downloader is intended to perform three requests in sequence:

1. `/truncated.bin`: receive 4,097 body bytes with the full image size advertised, reject the incomplete image, and release the firmware writer.
2. `/corrupt.bin`: receive a complete image with a modified first byte, reject the SHA-256 mismatch, and release the writer.
3. `/firmware.bin`: receive and commit the valid image, reboot into a different application, then verify its digest and installed version/size/CRC.

Earlier runs rejected the truncated case but stalled during the following full transfer, generally `/corrupt.bin`, at variable byte counts. Some instead failed during the second request's headers with `SEND FAIL`. These are historical failures; the fixed-Huffman run below completes all three requests and the changed-image reboot.

Observed during stalled runs:

- The helper is blocked in TCP `socket.out.write`, rather than in gzip inflation, according to its phase ticker.
- The Pico's before/after diagnostics show that completed `FirmwareWriter.write` calls returned. This does not prove that flash activity or scheduling cannot influence the network; it does show the observed stall is not simply a firmware write that never returns.
- Diagnostic `AT+CIPRECVLEN?` queries repeatedly reported zero buffered bytes on all links. This weakens the theory that application data is merely waiting in the modem because an `+IPD` notification was lost.
- Native instrumentation of the helper's TCP sender showed no free send-buffer space, queued unsent data, no unacknowledged segments at several observations, and a very small peer receive window.

Representative lines preserved in `build/rp2040-recovery/esp32-proxy.log`, around line 12094:

```text
TCP diagnostic full buf=0 queue=4 wnd=40 unacked=0x0 unsent=0x3fffad00 pending=5760
TCP diagnostic full buf=0 queue=4 wnd=136 unacked=0x0 unsent=0x3fffad18 pending=5760
TCP diagnostic full buf=0 queue=4 wnd=232 unacked=0x0 unsent=0x3fffacd0 pending=5760
TCP diagnostic full buf=0 queue=4 wnd=328 unacked=0x0 unsent=0x3fffad30 pending=5760
TCP diagnostic full buf=0 queue=4 wnd=424 unacked=0x0 unsent=0x3fffad00 pending=5760
TCP diagnostic full buf=0 queue=4 wnd=520 unacked=0x0 unsent=0x3fffad18 pending=5760
```

These are sender-side stack observations, not a packet capture. The window later changed and some slow progress occurred; do not characterize every run as a permanent zero-window deadlock. Why the advertised window remains so small while the AT-visible receive buffer is empty is unresolved. Modem receive-window accounting, sender segmentation/window handling, and timing interactions remain hypotheses.

## Tests that passed

| Coverage | Evidence |
| --- | --- |
| TCP backpressure, DNS, concurrent UDP and GC | `network-stress.toit`: three open/close cycles, each receiving and validating 65,537 TCP bytes after delaying reads, with 32 concurrent UDP datagrams; `build/rp2040-w2023-vm/network-stress-hardware-drain-fixed.log` |
| Authenticated TLS | Two 11,554-byte echoes with concurrent GC; wrong-host, untrusted-root and expired-certificate rejection; handshakes about 3.6 seconds; `build/rp2040-w2023-vm/modem-tls-hardware-empty-fixed.log` |
| Separate installed network containers | Shared clients, exit with open resources, termination during blocked reads, subsequent reuse and UART release; `build/rp2040-w2023-vm/service-containers-hardware-retry.log` |
| Standard firmware service | Current-image self-copy, checksum and incomplete-image rejection, writer cleanup and reboot; `build/rp2040-w2023-vm/firmware-service-hardware-v48.log` |
| Changed-image firmware service over USB | Streamed 602,116 bytes into `FirmwareWriter`, rejected incomplete and corrupt transfers, verified different image after upgrade with concurrent GC; source 196 → target 197 → restored smoke 198; `build/rp2040-w2023-vm/firmware-stream/hardware.log` |
| Full-image raw TCP | Validated all 602,116 deterministic bytes in 74,708 ms, UART errors zero; `build/rp2040-w2023-vm/network-paced/hardware.log` |
| Paced raw TCP | 2 KiB bursts / 300 ms pauses: 93,099 ms; same log. 4 KiB bursts / 600 ms pauses: 92,794 ms; `build/rp2040-w2023-vm/network-paced-window/hardware.log`. Both validated 602,116 bytes with zero UART errors and used the original driver without polling. |

The passing 65,537-byte burst is particularly useful as a comparison: its helper writes deterministic data in 1,024-byte chunks. The failing HTTP path adds headers, gzip inflation at the sender, separate network-service RPC, firmware writes, and a preceding truncated transaction. The full-image and paced raw TCP comparisons above now isolate total size and two pacing patterns. Neither reproduced the HTTP stall; they do not rule out other packetization or sender-timing effects.

## Experiments already performed

All log names below have prefix `build/rp2040-w2023-vm/network-ota-hardware-`. Byte counts are observed progress for individual runs, not a repeatable failure threshold. Helper counts represent completed application writes, not necessarily bytes received by the Pico. Several stalled runs were interrupted to restore the boards before their full timeout expired.

| Experiment | Observation | Log suffix |
| --- | --- | --- |
| Query pending receive lengths while idle | Repeatedly zero; firmware writes had returned | `idle-probe.log` |
| Add helper phase tracing | Helper blocked in TCP write; one run stopped progressing at 1,536 helper bytes / 256 body bytes | `stages.log` |
| Clear SDK TCP readiness before primitive operation | Still stalled; experimental host TCP tests passed but hardware did not improve | `readiness.log` |
| Enable helper TCP_NODELAY after the stall | Did not release the blocked write | `nodelay.log` |
| Instrument helper native TCP state | Small peer window with queued unsent data and empty unacknowledged list at the observations above | `native-tcp.log`, plus helper proxy log |
| Query `CIPRECVLEN` before each pull, cap reads to available bytes, skip empty pulls | Still stalled at 12,040 body bytes / 17,224 helper bytes; pending lengths zero | `exact-read-retry.log` |
| Increase AT read request to 2,920 bytes | Modem rejected the command with `ERROR`; receive-buffer capacity must not be confused with command read-length limit | `large-read.log` |
| Increase AT read request to 2,048 bytes | Still stalled at 8,672 body bytes / 12,836 helper bytes | `read2048.log` |
| Send `AT+RST` and wait for modem `ready` before provider setup | Still stalled at 7,552 body bytes / 13,092 helper bytes; stale state across previous runs is insufficient as an explanation | `modem-reset.log` |
| Batch inflated output into 1,024-byte writes | Still stalled at 2,464 body bytes / 6,144 helper bytes | `batched-writes.log` |

The software reset was before the complete three-request scenario; it does not rule out a problem caused by the first truncated request within that scenario. Likewise, the NODELAY experiment weakens a simple Nagle explanation without excluding other sender-side problems.

## Feedback follow-up

The review in [the feedback document](rp2040-esp8285-wifi-feedback.md) is analysis,
not hardware evidence. Its proposed old-lwIP receive-window explanation remains
a hypothesis; no packet capture has established that mechanism.

Current disposition of the review:

| Suggestion | Result |
| --- | --- |
| Remove timing diagnostics | Provider DEBUG, per-chunk prints, ticker and forced inflation batching removed; clean comparisons and full OTA completed. Optional memory probing remains off by default. |
| Correct AT log wording | Handled callbacks now log `dispatched via callback`. |
| Poll after a lost notification | Pending TCP reads recheck `CIPRECVLEN` once per second; host regression passes. This alone did not fix HTTP stalls. |
| Test paced full-image raw TCP | Both suggested pacing controls passed with the original driver. |
| Read UART error counters during stalls | Direct HTTP stalls reproduced with zero UART errors and without flash writes or provider RPC. |
| Capture Wi-Fi packets | Not done; the small-window causal explanation remains unproven. |
| Consider active receive mode | Not adopted: flash erase disables interrupts, and unsolicited payloads can overflow the 32-byte UART FIFO. More free heap does not prevent that loss. |

The installed source also retries refused TCP data from `tcp_fasttmr` every
250 ms; it does not require another incoming segment. See the source analysis
below. Keep the confirmed modem lifetime bug separate from the unproven stall
explanation.

The suggested full-image raw TCP comparison passed, including both pacing
patterns recorded above. The original driver was used throughout, without the
new polling fallback. The 4 KiB test retained a shadow package at
`/tmp/rp2040-cellular-before-poll`; its driver SHA-256 is recorded in
`build/rp2040-w2023-vm/network-paced-window/control.json`.

The next comparison, `http-download.toit`, uses the same HTTP/gzip sender and
truncated-then-corrupt request sequence but owns the UART directly, performs no
firmware writes, starts no network-service container, and has no forced GC task.
With the original driver, application 203 rejected the 4,097-byte truncated
body, then stalled at **6,784 bytes** of `/corrupt.bin` until its 180-second
deadline. **UART errors remained zero**, including at the final observation.
The helper reported being blocked in TCP write after 12,288 completed body
bytes. Evidence: `build/rp2040-w2023-vm/http-direct-original/hardware.log`,
`control.json`, and the retained source/snapshot/envelope alongside them.

This reproduces the failure without flash writes or service RPC, so neither is
required to trigger it. It does not rule out additional UART-loss problems when
flash writes are present. The helper diagnostics and batching were deliberately
unchanged for this comparison. They have since been removed from the source;
the cleaned comparison and subsequent OTA results are recorded below.

The new lost-notification fallback has a host regression that deliberately
withholds `+IPD` while retaining bytes in the emulated modem. It failed with
`DEADLINE_EXCEEDED` before the fix and passes afterward. The test also checks
that an empty pending-length reply does not become EOF, caller deadlines still
expire, and later traffic succeeds. All four cellular host suites pass with
both the current SDK and SDK alpha.196. Logs are
`/tmp/cellular-poll-{current,sdk196}-{at-test,esp8285-test,esp8285-cancel-test,esp8285-service-test}.log`.
The hardware comparison with polling also stalled: application 205 stopped at
1,024 body bytes during its **first** `/truncated.bin` request until the
180-second deadline, with zero UART errors. The helper reported being blocked in write after the same 1,024-byte
count. Its helper code was unchanged from the original-driver comparison.
Evidence: `build/rp2040-w2023-vm/http-direct-poll/hardware.log` and `control.json`.
Thus polling does not resolve the observed failure, and a preceding truncated
request is not necessary to trigger it. Byte counts vary; this pair does not
establish a polling-related regression in where a stall occurs.

The cleaned OTA fixtures analyze and build successfully. The initial prepared
images and assets are in `build/rp2040-w2023-vm/network-ota-clean-no-debug`;
later hardware comparisons and complete OTA results are recorded below.

## Sender memory and modem source follow-up on 2026-10-01

The cleaned gzip helper still stalled: application 207 stopped at 19,584 body
bytes, UART errors zero, and timed out. Both boards restored (smoke 208).
Evidence: `build/rp2040-w2023-vm/http-direct-clean/hardware.log`.

Replacing gzip inflation with a deterministic 256-byte `PatternReader`, while
keeping the same HTTP framing and three-request sequence, passed. Application
209 rejected the truncated body, received all 602,116 corrupt bytes in 74,263 ms,
and verified all 602,116 valid bytes in 74,345 ms. UART errors stayed zero;
smoke 210 and the ordinary helper were restored. The original compressed asset
was retained in flash but not decoded. Evidence:
`build/rp2040-w2023-vm/http-pattern/hardware.log` and `control.json`.
This implicates a difference introduced by inflation (including timing, memory,
or data content); it does not by itself identify a modem defect.

A helper-only memory probe waited for a stall, then collected garbage. It logged
`free=1664->26624 largest=848->8192` with the writer blocked after 7,424 completed
body bytes. The Pico subsequently advanced from 3,232 to 20,512 bytes, before the
helper reported `OUT_OF_MEMORY` and stopped. Its heap report showed 57,344 bytes
reserved for the helper process and about 1 KiB system free. This is concrete
sender memory pressure, previously missing from the window investigation.
Evidence: `build/rp2040-w2023-vm/http-memory-probe/hardware.log` and the helper
proxy log (program `1fa3e35f-2426-73b6-8472-f4ff1a8705c7`). Smoke 212 restored.

The firmware runner now compresses with a 1 KiB window and supplies the same
window to `GzipDecoder`. The compressed image remains small enough for the
helper's program partition. This bounds live history but is **not a verified
stall fix**: application 213 still stopped at 3,232 corrupt-body bytes with zero
UART errors and restored smoke 214. See
`build/rp2040-w2023-vm/http-small-window/hardware.log`.

Native helper diagnostics in application 215 confirmed repeated `tcp_output`
failures with `ERR_MEM` (`-1`). Free system memory was 3,016–3,120 bytes and the
largest free block was 1,048 bytes. When the sender filled its send buffer,
the peer window was **2,920**, the send queue had four packet buffers, and both
unacknowledged and unsent segments existed. This run does not fit a modem
advertising only a 40-byte window. The Pico again stalled at 3,232 corrupt-body
bytes with zero UART errors. Evidence:
`build/rp2040-w2023-vm/http-native-memory/hardware.log` and
`build/rp2040-recovery/esp32-proxy.log` (search `TCP memory`).

The original SDK ignored `tcp_output` errors after a successful `tcp_write`.
Once the queue fills, the next write waits for an acknowledgment without
requesting GC. Returning an allocation failure after accepting bytes would be
unsafe: the primitive retry could queue the same bytes again. A helper-only
experiment instead retries pending output before accepting additional bytes,
allowing allocation failure to trigger GC before the new write has side effects.
This experiment failed in application 219: the corrupt body stopped at 4,672
bytes with zero UART errors. The helper reported a 40-byte peer window, no
unacknowledged segments, four queued packet buffers, 2,872 free bytes and an
848-byte largest block. Thus allocation failure and a constricted peer window
have both been observed; retrying output before writing is insufficient.
Evidence: `build/rp2040-w2023-vm/http-native-retry-second/hardware.log`.
The experiment and native logging have been removed.

The SDK now has a candidate correction using its existing GC notification:
after a successful enqueue, an output `ERR_MEM` requests GC through the socket
event without retrying the enqueue. The Toit event loop now clears the GC bit
before collecting. Previously that bit remained set, so the loop could service
the same request indefinitely even after the native global request was cleared.
Four existing host socket suites pass. The focused hardware regression fails
with the original library (`DEADLINE_EXCEEDED` on its first write) and passes
with the correction: three verified read/write rounds. Snapshots and logs are
under `build/rp2040-w2023-vm/tcp-gc-event/`. Dynamic gzip still stalled in
application 221 at 2,048 corrupt-body bytes with zero UART errors; smoke 222 and
the helper both restored successfully. See
`build/rp2040-w2023-vm/http-tcp-gc/hardware.log`.
`tests/hw/rp2040/tcp-gc-esp32.toit` injects this bit on real loopback sockets
to check read/write progress and repeated event consumption. It requires lwIP;
the ordinary host backend deliberately does not implement the GC primitive.

A minimal sender with the exact firmware as a raw asset was also built, but its
696,960-byte image exceeds the helper's 655,360-byte program partition. It was
not deployed; the source and image are retained under
`build/rp2040-w2023-vm/http-raw/` only.

Fixed Huffman gzip coding **passed** the same direct HTTP test in application
223: truncated 4,097 bytes rejected, complete corrupt body in 74,289 ms, and
complete valid body in 74,349 ms with SHA-256 verified. Both full bodies were
602,116 bytes; UART errors stayed zero. Smoke 224 and the ordinary helper were
restored. This changes compression strategy, retaining the 1 KiB history and
identical decompressed firmware. It avoids rebuilding dynamic lookup tables,
but can also change sender timing and chunk boundaries; this is not proof that
the residual stall has only one cause. See
`build/rp2040-w2023-vm/http-fixed-huffman/hardware.log` and `control.json`.
The firmware runner now defaults to fixed coding and retains
`--gzip-strategy dynamic` as a diagnostic control. Full OTA subsequently passed
with this setting; see the latest results below.

Separately, the public NONOS SDK at the exact installed-image source commit
`8e1386548cdca53f24e4758b5fc8494791ee060b` contains a passive receive lifetime bug.
[`espconn_tcp_recv`](https://github.com/espressif/ESP8266_NONOS_SDK/blob/8e1386548cdca53f24e4758b5fc8494791ee060b/third_party/lwip/app/espconn_tcp.c#L563)
copies one packet buffer, frees it, then reads its next pointer. The matching
[`pbuf_free`](https://github.com/espressif/ESP8266_NONOS_SDK/blob/8e1386548cdca53f24e4758b5fc8494791ee060b/third_party/lwip/core/pbuf.c#L688)
can free the whole chain. The official image has the same sequence: a free call
at file offset `0x448da`, then a load through the freed pointer at `0x448dd`;
the called chain-free function is at `0x4827c`. Image SHA-256 is
`3040890680ba1071c1791eeb371b5f83609bc98383b47fe7e378db9a9e18c681`.

`nonos-receive-test.py` compiles the actual two SDK functions with host stubs.
AddressSanitizer detects the original use-after-free; copying all chained
payloads before freeing the chain passes. Run it with `--sdk LOCAL_SDK_CHECKOUT
--output OUTPUT_DIRECTORY`. Retained logs, generated C and source hashes are in
`build/rp2040-w2023-vm/nonos-receive-source/`. This proves the lifetime defect,
**not its responsibility for our hardware stall**. Modem firmware has not been
changed. The same revision's
[`tcp_fasttmr`](https://github.com/espressif/ESP8266_NONOS_SDK/blob/8e1386548cdca53f24e4758b5fc8494791ee060b/third_party/lwip/core/tcp.c#L1015)
retries refused data periodically, so the feedback's claim that another incoming
segment is required does not describe this source revision.

## Send interruption and binary framing follow-up

Hardware probes on the installed NONOS AT 1.7.6.0 image establish the following:

- A standalone `+++` after a 50 ms UART gap cancels an ordinary length-delimited
  `CIPSEND`, for both TCP and UDP. Tests interrupted a 65-byte payload after
  0, 7, 63 and 64 bytes. All returned `SEND Canceled`; subsequent echoes on the
  same socket had no leftover prefix or truncated datagram. This is evidence
  for the tested UART timing, not a framing-independent cancellation primitive.
- A literal three-byte `+++` payload is also canceled. Sending one plus sign,
  pausing 50 ms, then sending two more delivers the intended payload. This is
  a binary-transparency defect, not an application cancellation request.
- CIPSENDEX correctly echoes all byte values and 1,460 escaped backslashes when
  sent continuously. However, sending `A` and the first escape backslash,
  pausing 50 ms, then sending the second backslash, `B` and the terminator
  produces **four bytes**, with two backslashes. The intended payload has
  three bytes. Switching the driver to CIPSENDEX would introduce corruption.

The retained `send-abort-probe.toit` asserts these installed-firmware behaviors;
its PASS marker does **not** certify correct modem behavior. It sends only to
our isolated echo fixture. Its emergency filler is test cleanup and must not
be copied into a production recovery path. UART receive-handler disassembly
from the matching vendor archive corroborates both batching-dependent paths.

Evidence under `build/rp2040-w2023-vm/`:

| Fixture | Result | Application / restored smoke |
| --- | --- | --- |
| `sendex-probe/hardware.log` | Continuous encoded binary echoes pass | 301 / 302 |
| `send-abort-probe/hardware.log` | TCP and UDP abort and reuse pass | 303 / 304 |
| `send-framing-probe/hardware.log` | Both binary framing defects reproduced | 305 / 306 |
| `send-canceled-fixed/hardware.log` | Adapter reports completed error; both sockets remain usable | 309 / 310 |

The cellular adapter now recognizes `SEND Canceled` as a completed error instead
of timing out and closing every socket. The added host regression failed with
`DEADLINE_EXCEEDED` before the fix and passes afterward for both protocols.
All four host suites pass. The first adapter hardware assertion expected an
empty response list; the modem prompt's trailing space instead produced a
nested empty list. Version 307 failed that assertion and restored 308. The
retained test checks the error code and successful subsequent traffic; version
309 passes. This fix does not make arbitrary binary writes safe on NONOS.

A newer official ESP-AT build is prepared locally for evaluation, retaining the
AT protocol. Espressif documents a 1 MiB ESP8285 configuration on its
[ESP8266 release branch](https://docs.espressif.com/projects/esp-at/en/release-v2.2.0.0_esp8266/AT_Binary_Lists/ESP8266_AT_binaries.html).
The candidate uses ESP-AT commit `5249c31d1df78c68622b33ffa9fd82b9991c28be`,
its pinned RTOS SDK `ff16a35c362047b47c0b3d29c02ef9755b623447`, DOUT/40 MHz,
and UART0 TX GPIO1 / RX GPIO3 at 115200, without flow control or control GPIOs.
The complete image is 1 MiB; its 873,728-byte application fits the 917,504-byte
partition. Its build, image checksum, partition placement and factory UART
parameters have been checked. Artifacts, configuration patch and hashes are in
`build/rp2040-w2023-native/esp-at-2.2/`.

**The candidate was flashed on 2026-10-02, but fails acceptance.** The current
cellular driver still targets NONOS commands and framing. Modern AT uses
different volatile configuration commands and passive receive framing, and
also applies passive mode to UDP. Integration and recovery tests are still
required; a successful build is not evidence that these defects are fixed.
Replacing the modem firmware requires a coordinated wireless-BOOT power cycle.
The Pico recovery loader does not need replacement. The native USB/modem bridge
was initially installed as application 311. After approval and the physical
wireless-BOOT step, the full installed flash was backed up to
`build/rp2040-w2023-native/esp-at-2.2/pre-at2-20261002.bin`. The approved image's
SHA-256 remained `be9d6e5f8ee773dd8896f0e4fab4e223d65e377e6da98e1071b3f194f8a22133`;
esptool verified the written data, and native GMR reported AT 2.2.2.0 with zero
UART errors. See `hardware-install-20261002.json` and its referenced logs there.

`at2-probe.toit` application 312 failed on its first TCP literal-`+++` send with
`SEND Canceled`; smoke 313 was restored. Application 314 selected the passive
tests independently, but timed out before printing GMR, so it gives no passive
receive result; smoke 315 was restored. Logs are
`build/rp2040-w2023-vm/at2-probe/hardware-20261002.log` and
`build/rp2040-w2023-vm/at2-passive/hardware.log`.
The native bridge was reinstalled as application 316. Neither `AT`, `AT+GMR`,
nor `AT+RST` elicited any bytes (`resync-20261002.log` in the candidate directory).
The old fixture's 4 KiB filler cleanup is not a validated recovery method for
AT 2.x and has been removed. The updated fixture attempts a bounded ordinary
reset only on an open session; otherwise it requests a modem power-cycle.
A normal power-cycle, without either BOOT button, restored GMR responses with
zero UART errors (`gmr-after-powercycle.log`). Application 317 then passed
passive TCP and single-datagram UDP binary/metadata checks, but failed the first
queued UDP assertion: expected 97 bytes, received 308. Smoke application 318
was restored and passed. The log is
`build/rp2040-w2023-vm/at2-passive-retry/hardware.log`; the exact source and image
are retained beside it. No reset-cleanup acknowledgement appears in that log,
so it does not establish modem recovery after the assertion. No Pico recovery
loader was changed. The firmware's binary framing and recovery still need work.

October 6 follow-up:

- Initial USB application updates received no recovery response. The verified
  helper RUN pulse restored access; the helper Wi-Fi fixture was then restored
  and its READY marker verified. No loader or modem firmware was replaced. The
  cause of the silent USB connection is unknown and remains a platform follow-up.
- Application 319 failed when switching CIPMUX with a stale single-mode link.
  The trace identifies CIPMUX=0, after the invalid single-mode CIPCLOSE=5 attempt.
  Its bounded AT+RST cleanup was acknowledged; smoke 320 passed. The fixture now
  queries the current mux mode and uses the matching close command.
- Application 321 passed a backslash escape split by a 50 ms UART gap, on TCP
  and UDP. Smoke 322 passed. Evidence: `at2-sendex-20261006/hardware.log` under
  `build/rp2040-w2023-vm/`. This distinguishes modern AT from the NONOS defect.
- Application 323 selected the 1,009/907-byte queued UDP pair, but timed out in
  CIPSEND before the queue barrier or receive checks. The captured stack is in
  `at2-queued-large-20261006/decoded-fixed-setup.log`. Smoke 324 passed. The log
  does not identify which of the two sends timed out; additional stage logging
  has been added. This run does not demonstrate truncation or its cause.
- Application 325, the escaped-binary diagnostic, failed before GMR. Its AT+RST
  attempt also timed out; smoke 326 passed. Evidence:
  `at2-sendex-binary-20261006/hardware.log`. A physical modem power-cycle is
  was needed before rerunning this test; Pico RUN does not reset the modem.
- After that confirmed power-cycle, application 327 passed all escaped binary
  cases on TCP and UDP; smoke 328 passed. Evidence:
  `at2-sendex-binary-retry-20261006/hardware.log`. This validates the tested
  three-byte/3 ms fragmentation pattern, not all possible UART scheduling.
- Application 329 used the same escaped-send path to queue 1,009 and 907 UDP
  bytes. The first pull returned their exact concatenated 1,460-byte prefix;
  CIPRECVLEN then reported zero, establishing loss of the remaining 456 bytes.
  UART errors were zero and cleanup reset was acknowledged; smoke 330 passed.
  Evidence: `at2-queued-large-escaped-20261006/hardware.log`.

The fixture's old `expect` calls exit the process, skipping its finally cleanup.
They now throw instead; the run-319 reset acknowledgement verifies that cleanup
can execute on a command error. No cleanup guarantee is inferred for an
unsynchronized payload transfer. No filler is sent.

The same stale-link problem existed in the cellular adapter's initial connect.
It now reads CIPMUX and closes a single link with CIPCLOSE, or multiple links
with CIPCLOSE=5, before changing modes. A host regression starts with a stale
UDP link in each mode and checks a subsequent TCP exchange. It fails before
the change and passes afterward. All four host suites pass with the current
SDK and v2.0.0-alpha.196. The adapter still speaks NONOS; this fix does not add
AT 2 support. Local evidence is retained in
`build/rp2040-w2023-native/stale-link-validation/`.

Because modern split escapes pass, CIPSENDEX with both `+` and `\` escaped is a
candidate binary-send solution: the encoded stream cannot contain three
consecutive plus signs. The `sendex-binary` selection tests full-size binary,
all-plus and all-backslash payloads with deliberately fragmented UART writes.
That selection now passes on hardware (application 327). It has not yet been
adopted in the adapter. Passive UDP still
needs a separate firmware correction, including empty datagrams; merely
enabling lwIP's first-datagram length mode does not fix the AT core's rejection
of zero-byte reads.

Independent of the modem firmware, `Session.close` now waits for receive-task
cleanup before returning to an external caller. The wait ignores caller
cancellation/deadlines but has its own one-second limit. Calls from the receive
task itself skip the wait. A host test with yielding reader cleanup fails before
the change and passes afterward. Tests also cover close before the reader starts
and close from a response callback. The latter also reproduced dispatch of
already-buffered notifications after close; the receive loop now stops when
closed. All four cellular host suites pass. This
shutdown change has not yet been exercised on hardware and does not itself
resynchronize the modem or interrupt an independent caller's command write.

Further host regressions exposed missing payload deadlines in the shared AT
session. Command headers are written by the caller under a deadline, but the
receive task formerly wrote prompted payloads without that deadline. A blocked
payload writer could survive the caller's timeout. A prompt arriving after a
timeout could also transmit the abandoned payload; this was reproduced with a
three-byte payload. Cancellation before the prompt likewise left the shared
session open (the ESP8285 adapter already had its own failure handling).

Payload writes and their optional delay now obey the command deadline. A data
command interrupted before its final result closes the session, preserving the
cancellation or timeout cause. Completed modem error responses remain usable;
ordinary and raw commands retain their previous timeout behavior. Regressions
cover blocked payload writes, late prompts, cancellation before the prompt,
and ordinary/raw command reuse. All four cellular host suites pass. The before
logs are `/tmp/cellular-payload-deadline-before.log` and
`/tmp/cellular-payload-before-test-{late-data-prompt,cancel-before-data}.log`;
the final suite logs are `/tmp/cellular-payload-final-*.log`. Source hashes and
retained copies are in `build/rp2040-w2023-native/at-payload-deadline/`.
This change is host-tested only. It stops abandoned Toit writes, but does not
resynchronize a modem that already received an incomplete payload.

The current four host suites also pass on the package's minimum supported SDK,
alpha.196, including those payload-deadline changes. Additional UDP receive
regressions pass on both SDKs: empty datagrams remain distinct from EOF,
MTU-sized datagrams are preserved, and oversized datagrams up to 65,535 bytes
and frames for unused links are drained without interpreting embedded AT-looking
bytes. Subsequent command responses and datagrams remain intact. These checks
needed no adapter change. They exercise simulated UART input and do not establish
empty-datagram transmission by either modem firmware. Logs and source hashes
are retained in `build/rp2040-w2023-native/udp-boundary-validation/`.

## Newer AT passive UDP compatibility

Static review of the prepared ESP-AT 2.2 candidate found an additional migration
gate: its passive receive path concatenates queued UDP datagrams.
**Hardware application 317 reproduced the boundary loss:** with 97- and
211-byte echoes queued, `CIPRECVLEN` reported 308 and the first `CIPRECVDATA`
returned 308 bytes instead of the expected 97. The assertion stops before
checking the merged bytes, the second pair, or sender mixing. Single TCP and
UDP echoes passed; those checks alone were insufficient to cover this behavior.

Preprocessing the candidate's actual `sockets.c` compilation command confirms
`LWIP_FIONREAD_LINUXMODE=0` and `CONFIG_LWIP_SO_RCVBUF=1`. In the pinned RTOS SDK,
`lwip_ioctl(FIONREAD)` consequently returns aggregate queued UDP bytes, rather
than the size of the first datagram. The AT core's `at_get_link_available_bytes`
calls that ioctl. Its `at_process_passive_read_event` disassembly shows a loop
that appends successive `lwip_recvfrom` results until it reaches the smaller of
the requested length and initial available count. The loop overwrites the same
sender-address storage for each datagram.

Together, these paths explain the measured boundary loss and imply that the
merged record has the last sender's metadata. If a later datagram exceeds the
remaining requested byte count, lwIP discards its unread suffix. Sender mixing
remains a source/disassembly deduction. Application 329 confirms truncation:
the response matches the concatenated prefix exactly, and the unread suffix
is no longer available. Zero-length datagrams still need testing: the AT path treats an available byte count of zero as no data.

The acceptance fixture now queues 97- and 211-byte echoes, then separately
1,009- and 907-byte echoes. It waits for `CIPRECVLEN` to report both complete
echoes before requesting 1,460 bytes, and requires each response to contain one
unchanged datagram. This covers concatenation and a read limit that cuts through
the second datagram. A queue-barrier timeout is inconclusive; this barrier
specifically requires aggregate-length semantics and must change if a future
firmware reports only the first datagram's length. The first pair failed on
hardware; the second pair subsequently failed independently using escaped
sends in application 329.

Evidence is retained in
`build/rp2040-w2023-native/esp-at-2.2/vendor/passive-udp-audit.json`,
`udp-macros.txt`, `available-bytes.dis`, and `passive-read.dis` in that directory.
The audit records source/image hashes and the exact preprocessing command.

There is no documented per-connection receive-mode setting in either the
[ESP8266 AT 2.2 command set](https://docs.espressif.com/projects/esp-at/en/release-v2.2.0.0_esp8266/AT_Command_Set/TCP-IP_AT_Commands.html#cmd-CIPRECVMODE)
or the
[AT 2.3 command set](https://docs.espressif.com/projects/esp-at/en/release-v2.3.0.0_esp8266/AT_Command_Set/TCP-IP_AT_Commands.html#cmd-CIPRECVMODE).
Thus selecting active UDP and passive TCP is not an established workaround.
Enabling lwIP's first-datagram length mode is a possible firmware experiment,
not a complete fix: empty datagrams, oversized datagrams, notifications and
sender metadata still need verification. Do not add modern passive UDP to the
cellular adapter based only on the earlier single-echo probe.

## Current source state

Experimental AT receive correction, installed and tested October 6:

- Source: `tools/rp2040/esp-at/udp-receive.c`; adds `+TOITUDP` while preserving
  ordinary AT commands. One nonblocking recvfrom returns one datagram, including
  an empty one. A buffer one byte beyond the 1,460-byte MTU detects and discards
  oversized packets instead of returning a truncated prefix. Sender metadata
  accompanies every accepted packet.
- The pinned core exports `esp_at_get_socket_by_link_id`, though its old public
  header omits the declaration. The extension links successfully against it;
  newer [Espressif API documentation](https://docs.espressif.com/projects/esp-at/en/latest/esp32/Compile_and_Develop/AT_API_Reference.html)
  describes the same signature. No closed-core binary patch is applied.
- Real host UDP sockets pass ASan/UBSan checks for boundaries, mixed sender
  ports, empty/no-data distinction, oversized discard and invalid inputs. These
  are host results, supplemented by the hardware checks below.
- Candidate application: `build/rp2040-w2023-native/esp-at-udp-extension/esp-at.bin`,
  874,592 bytes in a 917,504-byte partition, SHA-256
  `369dc93f55c24d08b133d4f11664105c468657d55d84f36a570204110be2b6ae`.
  Its full factory image's first 128 KiB match the approved stock image exactly.
  The user approved installation and performed the wireless-BOOT power-cycle.
  Only the application at 0x20000 was written; esptool verified its hash.
  The complete pre-extension flash backup is
  `build/rp2040-w2023-native/esp-at-udp-extension/pre-extension-20261006.bin`,
  SHA-256 `0f951b1a11b1e3372cc1d1fb2d4b41f005b7ac27be97078a4cf6cf254cacf4a2`.
  The modem bootloader/settings and Pico recovery loader were preserved.
- `tests/hw/rp2040/modem/udp-extension-probe.toit` and its firmware image are
  tested against the helper's UDP boundary fixture on ports 4246 and 4247.
  Application 337 passed all six packets over two open/close cycles: 1,009,
  907, zero, 1,460, oversized 1,461 (discarded), then three bytes. It verified
  exact payloads, alternating sender ports, and empty-queue status. UART errors
  were zero; smoke application 338 passed after restoration. Evidence:
  `build/rp2040-w2023-vm/udp-extension-retry/hardware-after-rom-restart.log`.
  The strengthened fixture then passed in application 339: two bursts on each
  socket across two open/close cycles, including an empty-queue read between
  bursts. UART errors remained zero and smoke restore 340 passed. Evidence:
  `build/rp2040-w2023-vm/udp-extension-reuse/hardware.log`.
- This remains experimental. It requires passive mode and does not update the
  original core's pending-notification flag; UDP readers need a polling fallback.
  The cellular adapter has now been ported; see the latest update above for
  its narrower hardware coverage and the remaining empty-send defect.

The initial hardware attempt (application 332) did not test datagram reception:
the helper fixture crashed because a List.do callback expected two arguments.
Both helper and probe now iterate indices explicitly. Cleanup acknowledged
AT+RST, but the next attempt (334) timed out on AT before reaching the test.
Native bridge application 336 then received eight valid ROM SYNC replies and
no AT response. This establishes ROM download mode in this case, rather than
an unresponsive modem. It does not establish the cause of earlier silent runs.

Without another power-cycle or flash write, esptool's legacy v1 RAM stub and
`--after soft-reset flash-id` started the existing firmware; application 337
then passed. The reproducible wrapper is
`tools/rp2040/inspect-modem.py --start-application`, with the usual verified Pico
`--port` and `--id` arguments.
It requires the native bridge application and a modem already in download mode;
it is not a general recovery mechanism for interrupted AT payloads. Evidence:
`build/rp2040-w2023-native/esp-at-udp-extension/reset-rom-diagnostic.log`
and `remote-restart.log` in the same directory. The reset-to-ROM behavior may
be related to the boot mode retained after flashing; the precise cause remains
unverified.

The cellular driver still requests **512 bytes** per passive TCP read. Following the feedback review, a pending reader now rechecks `CIPRECVLEN` after one second without a notification. This is a lost-notification fallback, not a demonstrated fix for the HTTP stall. There is no query before every read or SDK write-readiness reordering. The AT receive-loop log now correctly labels lines dispatched through its callback. Root SDK TCP sources contain the GC-event correction described above; the helper build copy matches them. Allocation diagnostics and the pre-write output retry experiment have been removed. The original native source is saved at `/tmp/rp2040-helper-tcp-before-memory.cc`.

The fixture sources now use INFO provider logging and no per-write prints, helper phase ticker, or forced 1,024-byte inflation batching. Historical failure logs and the original/polling direct-HTTP comparison used the earlier diagnostics; their helper source is retained as `used-firmware-server.toit` in the comparison output directories. Do not treat those runs as validation of the cleaned fixture.

Relevant files:

| File | Purpose |
| --- | --- |
| `/home/flo/work/cellular/src/modules/espressif/esp8285.toit` | Network adapter, passive TCP reads, socket state, AT commands, cleanup |
| `/home/flo/work/cellular/src/modules/espressif/service.toit` | Standard network-service provider |
| `/home/flo/work/cellular/src/base/at.toit` | Shared AT command ownership, parsing and cancellation |
| `tests/hw/rp2040/modem/firmware-download.py` | Builds both images, deploys helper assets, runs test and restores both boards |
| `tests/hw/rp2040/modem/firmware-download.toit` | HTTP receive loop, firmware writes and rejection assertions |
| `tests/hw/rp2040/modem/firmware-server.toit` | Helper HTTP response and gzip asset inflation |
| `tests/hw/rp2040/modem/firmware-received.toit` | Post-upgrade digest verification |
| `tests/hw/rp2040/modem/service-provider.toit` | Provider container and lifecycle observations |
| `tests/hw/rp2040/modem/network-stress.toit` | Passing burst/backpressure comparison |
| `tests/hw/rp2040/wifi-peer-esp32.toit` | Helper AP and all network services |
| `lib/net/modules/tcp.toit`, `src/resources/tcp_esp32.cc` | Helper SDK/native TCP implementation |
| `src/event_sources/firmware_rp2040.cc` | Asynchronous firmware worker |

The adapter uses passive TCP mode with multiple connections. The tested NONOS response format is `+CIPRECVDATA,<length>:<payload>`, unlike some newer ESP-AT releases. Avoid assuming current ESP-AT documentation describes this firmware.

Earlier fixes already in the working tree should be preserved: prepare AT response state before a yielding command write; accept unquoted IPv4 DNS replies; drain passive TCP data after `CLOSED`; handle bare `OK` from an empty passive read; isolate cancelled AT sessions and wake blocked readers. These have targeted tests and hardware evidence where applicable. A new investigation should distinguish regressions in them from the remaining stall.

## Reproduction

Start with the existing local build artifacts and matching SDK. The helper firmware must support both TLS server and client mode because its ordinary fixture starts a TLS listener alongside HTTP. The prepared native base is `build/rp2040-pico_w_2023-envelope/firmware.envelope`.

To prepare the images without using hardware:

```sh
cd /home/flo/work/opentoit-pi-pico
TOIT_PACKAGE_CACHE_PATHS="$PWD/tools/.packages-bootstrap" \
python3 tests/hw/rp2040/modem/firmware-download.py \
  --toit build/host/sdk/bin/toit \
  --envelope build/rp2040-pico_w_2023-envelope/firmware.envelope \
  --output build/rp2040-w2023-vm/network-ota-review \
  --build-only
```

For hardware, verify there is only one helper serial proxy. If absent, start the following in a separate terminal; the existing proxy log contains historical diagnostic evidence, so append rather than overwrite:

```sh
JAG_TOIT_REPO_PATH="$PWD" build/pio-jag/jag monitor --proxy \
  --port /dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_d0b0fe3f59faea1181464c185fbcde76-if00-port0 \
  --force-plain >> build/rp2040-recovery/esp32-proxy.log 2>&1
```

Then run the fixture, choosing a fresh log name for each attempt:

```sh
TOIT_PACKAGE_CACHE_PATHS="$PWD/tools/.packages-bootstrap" \
python3 tests/hw/rp2040/modem/firmware-download.py \
  --toit build/host/sdk/bin/toit \
  --envelope build/rp2040-pico_w_2023-envelope/firmware.envelope \
  --output build/rp2040-w2023-vm/network-ota-review \
  --jag build/pio-jag/jag --helper pico-w-helper \
  --port /dev/serial/by-id/usb-Raspberry_Pi_Pico_50443405886E0B1C-if00 \
  --id 50443405886E0B1C \
  --restore-image build/rp2040-final-hardware/restore.bin \
  > build/rp2040-w2023-vm/network-ota-review.log 2>&1
```

The runner deploys the helper, installs the Pico downloader, and observes up to 660 seconds. Individual downloads have a 300-second deadline. Its `finally` blocks attempt to restore the Pico smoke image and ordinary helper fixture. Restoration can itself fail: inspect the final output. Do not overlap hardware runners or start another test while restoration is running. If stopping a stalled run, interrupt the Python runner gracefully and wait for cleanup; avoid killing it outright.

Success requires the exact application marker `RP2040 WiFi firmware: PASS changed image booted and SHA256 verified` plus the expected loader version, size and CRC. A restore-smoke `PASS` at the end of a failed run is **not** an OTA pass.

## Latest complete OTA and regression results

The latest allocator/PIO-accounting build passes full OTA in
`build/rp2040-w2023-vm/cmpct-accounting-fixed/network-ota/hardware.log`:
source 260 → target 261 → restored smoke 262. The target is 606,212 bytes,
CRC32 `692d7471`, SHA-256
`a7858b811dfceba9d707e1d957745cf9c369a3c115c261a9b80ea84e22b138a7`.
Truncated and corrupt downloads were rejected, and the
different application verified its SHA-256 after reboot. The normal helper
fixture was restored successfully. This run uses the cleaned fixtures, fixed
Huffman coding and a 1 KiB history, with a separate provider and concurrent GC.

Fresh tests using the same allocator/PIO-accounting native build also pass:

| Test | Installed / restored version | Log under `cmpct-accounting-fixed/` |
| --- | --- | --- |
| DNS, TCP backpressure and concurrent UDP, three cycles | 263 / 264 | `network-stress/hardware.log` |
| Authenticated TLS twice; wrong-host, untrusted and expired rejection | 265 / 266 | `tls/hardware.log` |
| Shared network clients, process-exit cleanup and UART release | 267 / 268 | `network-service/hardware.log` |

The separate-container twelve-cycle regression passed in version 246 with
the same allocator, before the independent PIO accounting correction. The
results establish this tested configuration; dynamic-gzip stalls and
interrupted AT payload recovery remain open.

Privileged OOM recovery also passes with this allocator: version 258 reached
USB recovery 1.66 seconds after the observed failure injection; smoke 259
restored. See `cmpct-accounting-fixed/system-oom-handshake/hardware.log`
under the same VM directory. The runner now waits for readiness and sends an
explicit trigger before observing the failure. The earlier version-256 run
missed the injection marker and is not counted as a pass.

`build/rp2040-w2023-vm/network-ota-fixed-huffman/hardware.log` records the
earlier complete passing run: source version 225 → target 226 → restored smoke 227.
The target is 602,116 bytes, CRC32 `81587161`, SHA-256
`e1b593549ca96395929bf958f091c3231399246e8c50e28573c61bc81b8f9613`.
The downloader rejected the 4,097-byte truncated response and the full corrupt
response before committing the valid image. The new application verified its
own digest after reboot. This includes the separate network provider, flash
writes and concurrent GC. Both boards were restored successfully.

The direct HTTP comparison also passed both full 602,116-byte responses with
zero UART errors: `build/rp2040-w2023-vm/http-fixed-huffman/hardware.log`,
version 223, restored 224. The helper uses fixed Huffman gzip coding with a
1 KiB history; `--gzip-strategy dynamic` retains the failing control. Fixed
coding avoids dynamic lookup-table construction, but also changes timing and
chunking. This result does not establish that every dynamic-gzip stall has been
fixed, or that the modem's confirmed lifetime defect is harmless.

Freshly compiled regressions are in `build/rp2040-w2023-vm/wifi-final/`:

| Test | Result | Installed / restored version |
| --- | --- | --- |
| Network stress | PASS | 228 / 229 |
| Authenticated TLS and rejection cases | PASS | 230 / 231 |
| Network service | PASS | 232 / 233 |
| Separate-container lifecycle | FAIL: stack-growth OOM in fourth client cycle | 234 / 235 |

The lifecycle log contains passing shared-client and abandoned-resource cycles,
then successful cleanup after forced termination during a blocked read. The
next shared-client cycle reports `rp2040 heap: out of memory in 'stack grow'
118:177`; the coordinator receives child exit code 1 instead of 0. The earlier
version-148 lifecycle pass therefore does not settle current readiness.
A diagnostic build reproduced the failure in version 236 with libc reporting
141,028 bytes allocated, 83,776 bytes free in 23 blocks, and 8,192 bytes still
uncommitted. The failing process had 8,192 bytes reserved and 6,816 allocated.
The OOM therefore did not reflect exhaustion of every byte of SRAM.

Disassembly of the linked newlib `_memalign_r` confirms it requests size plus
alignment and bookkeeping before splitting an aligned block. Consequently,
a freed aligned page can be unusable to `memalign` despite being large enough
for the requested page. An experiment made `OS::allocate_pages` fall back to `malloc(size)`
after `memalign` failed, accepting only an already-aligned result and freeing
unaligned results. This retained libc ownership without a private page cache
or forced fixture collections, but did not survive the longer test below.

The original four-cycle scenario passed with this fallback in version 238,
restored 239: `build/rp2040-w2023-vm/container-aligned-reuse/hardware.log`.
However, the extended twelve-cycle run failed on its final cycle in version
240 (restored 241), with 81,688 bytes free in 24 blocks. Decoding the child
exception locates the failed allocation in `Reader.read-bytes` while validating
a 3,001-byte TCP echo. See `container-aligned-repeat/hardware.log` and
`decoded-error.log` under the same artifact directory.

Trying ordinary allocation *before* `memalign`, to reuse pages before further
splitting larger blocks, also failed the extended run: version 242, restored
243, with 88,864 free bytes in 22 blocks plus 4,096 uncommitted. Artifacts and
the experimental source are in `container-aligned-first/`. **Both allocation
experiments were removed.** Neither experiment was a completed fix; the
subsequent page-aware allocator below replaces the original allocator.

The retained fixture repeats the four-cycle sequence three times with one
provider, clearing the forced-stop readiness flag between cycles. The improved
`OS::heap_summary_report` and serial-report primitive expose native heap and
process figures on Pico; free bytes do not imply a single block of that size.
Toit's existing `cmpctmalloc` on ESP32 and EC618 has a page allocator
specifically for 4 KiB-aligned VM chunks. A portable copy is now integrated
into RP2040: libc/newlib reentrant calls,
FreeRTOS and VM pages share the linker-defined heap. RP2350 retains its existing
allocator. Host ASan/UBSan checks pass in 32-bit and 64-bit builds, covering
mixed allocations, realloc preservation, exhaustion and isolated-page reuse;
`make rp2040-test` includes the host test, with the 32-bit variant enabled in CI.
All three RP2040 board cross-builds and the shared RP2350 build pass after the
PIO accounting correction below. Image vector and capacity checks also pass.
Broader hardware validation is in progress.

The first allocator run (244, restored 245) stopped because the helper's TCP
echo task let a connection-reset exception escape, terminating the helper and
its DNS listener. Its log identifies `wifi-peer-esp32.toit`'s read loop and the
Pico then reports `DNS Fail`; this was not a heap OOM. The helper now catches
errors per echo/burst connection, matching its TLS/HTTP handlers, while client
fixtures still validate every byte and deadline. After a helper reset and
successful redeployment, the identical Pico binary passed all twelve cycles
in version 246, restored to smoke 247. See `hardware-fixed-helper.log`.
Evidence is under `build/rp2040-w2023-vm/container-cmpct/`; host allocator
logs are under `build/rp2040-heap-test/`.

After the twelve-cycle test, the Pico was restored to smoke version 247,
size 586,568, CRC32 `136bbb73`, with a passing smoke test. Later tests below and
in the latest-results section supersede that installed version. The helper
uses the ordinary fixture and corrected SDK
TCP implementation without native diagnostic logging. Verify current process
state before using either device. The GP17 recovery loader is installed and
verified; ordinary reproduction must not replace it. The user requires
confirmation before loader flashing, and BOOTSEL is not remotely wired.
An earlier attempt (217) stayed in the loader; restore 218 and the identical
test binary as 219 booted automatically. That startup incident remains separate
from the HTTP result.

## Next investigation

1. Continue with the ESP8285 recovery work after the local platform audit.
   The page-aware allocator now also
   passes native recovery, crypto, UART, ADC/I2C/SPI, GPIO/PWM, USB stdin,
   reset/watchdog and interrupted storage checks; see the fresh validation
   table in [the platform guide](rp2040.md). All three board bundles pass
   local packaging tests. Persistent containers, storage exhaustion and
   envelope config/assets across reset also pass on this build. Evidence by
   requirement is in `build/rp2040-readiness-audit.json`.
   Two helper deployment timeouts required resets;
   their cause remains open and is recorded separately from the Pico results.
2. Validate recovery after an interrupted AT payload (see below).
3. If the dynamic-gzip/small-window stall is revisited, obtain packet sequence,
   ACK and advertised-window evidence before attributing it to the modem bug.
   Native helper allocation failures are confirmed; the complete causal chain
   for every stalled control remains open.

## PIO accounting found during allocator validation

The new memory-pressure diagnostics exposed an independent PIO bug: returning a
native transfer buffer as an external byte array created its finalizer without
registering the transferred bytes in the process heap. Finalization later
subtracted them. Five smoke cycles produced an external-memory deficit of
3,840 bytes (printed as unsigned `4294963456`). This predates the allocator
change and affects the shared RP2040/RP2350 implementation.

`take` now registers the buffer length only after successful proxy/finalizer
creation, before relinquishing the transfer's ownership. The retained
`pio-lifecycle.toit` repeats transfer/GC checks sixteen times and asserts
nonnegative allocated/reserved memory. Running that snapshot on the archived
unfixed native image fails the new accounting assertion after two iterations:
version 250, restored 251, `build/rp2040-w2023-vm/cmpct-accounting-before/`.
The corrected native image passes the same regression and the full PIO
lifecycle suite in version 252, restored 253:
`build/rp2040-w2023-vm/cmpct-accounting-fixed/pio-lifecycle/hardware.log`.
The repeated memory-pressure test also passes in version 254, restored 255;
its final report returns external accounting to zero and shows 123,280 bytes
free with a largest free block of 118,784 bytes. See
`cmpct-accounting-fixed/memory-pressure/hardware.log` under the same VM directory. The first memory-pressure workload
otherwise completed in version 248 (restored 249); its PASS marker alone did not
settle readiness because the diagnostics contradicted correct accounting.

## Separate unresolved cancellation issue

Cancellation during an AT send is currently fail-closed: host tests cover interruption around the prompt, payload and acknowledgment, blocked readers are released, and late responses cannot reopen the failed session. **Modem resynchronization after an interrupted payload is not solved.** If the modem still expects payload bytes, creating a new interface and issuing AT commands can feed those commands into the old payload instead.

This is a separate production-readiness issue, not a demonstrated cause of the normal download stall. It needs an explicit transaction-recovery design and hardware validation. The relevant host tests are `tests/at-test.toit`, `tests/esp8285-test.toit`, `tests/esp8285-cancel-test.toit`, and `tests/esp8285-service-test.toit` in the cellular repository.

The user explicitly deferred replacing AT with another modem protocol. Investigate and improve the current AT implementation first. Preserve unrelated RP2040, PIO and pixel-strip changes in these worktrees.
