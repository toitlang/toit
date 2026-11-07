# ESP8285 Wi-Fi hardware test

This test uses `cellular.base.at` from the sibling `cellular` checkout. It
requires the AT-session changes for CRLF command endings, binary response
prefixes and the intermediate `OK` before ESP-AT's data prompt.

The W-2023 board connects its ESP8285 to GP0/GP1. Earlier tests used Espressif
Nano AT 1.7.6.0, SDK 3.0.6-dev, with 1 MiB flash and DOUT mode. The
original modem flash must be backed up before replacing it; see the inspection
tool in `tools/rp2040`.

The current board runs AT 2.2.2 with version 2 of the Toit UDP extension. The
cellular adapter now uses this modern dialect, escaped binary sends and passive
UDP polling. Ordinary TCP/UDP, binary payloads, empty UDP sends and queued
datagram boundaries pass hardware checks through the public adapter.
The investigation handoff records exact images, evidence and remaining work.
Raw NONOS diagnostic fixtures below remain historical reproductions and should
not be run against modern firmware without adapting their command dialect.

Run `../wifi-peer-esp32.toit` on the helper ESP32. This provides an isolated AP
and TCP/UDP echo servers at `200.200.200.1:4242`. The credentials in the test are
public test credentials; the modern adapter uses `SYSSTORE=0` so association
does not save them as the modem's default connection.
Build the helper's Jaguar service snapshot with the corrected SDK TCP and UDP
libraries as well as its native firmware and test application. Reusing an old
`jaguar.snapshot` retains its old networking code even when the native firmware
is updated. Use the compiler version matching the helper envelope. Record the
snapshot hash alongside the firmware hash when investigating memory-pressure
or deployment failures.
The helper leaves the verified GPIO4-to-GP17 recovery wire as an input with a
weak pull-up. A low level at Pico reset deliberately holds the recovery loader;
the helper must not leave this wire biased low during ordinary update tests.

Configure the RP2040 VM build with:

```sh
cmake -S toolchains/rp2040 -B build/rp2040-w2023-vm \
  -DTOIT_RP2040_BUILD_VM=ON -DPICO_BOARD=pico_w_2023 \
  -DTOIT_RP2040_PROGRAM="$PWD/tests/hw/rp2040/modem/wifi-smoke.toit" \
  -DTOIT_RP2040_PROJECT_ROOT="$PWD/tests/hw/rp2040/modem"
cmake --build build/rp2040-w2023-vm --target toit-rp2040
```

The application compiles with its own package root. Compiler dependency tracking
includes imported package sources.
Upload through the persistent USB updater, expecting the exact marker
`RP2040 ESP8285 WiFi smoke: PASS`.

The test checks AT identification, Wi-Fi association/DHCP, and 32 distinct
512-byte binary echoes over each of TCP and UDP. It verifies byte equality,
UDP datagram lengths, and GC during transfers. TCP responses may span several
receive frames. The UART and AT session close at the end, leaving USB-control recovery available.

This validates the shared AT transport on real Wi-Fi hardware. The fixtures
below exercise the separate ESP8285 `net.Interface` adapter.

`passive-tcp.toit` exercises the installed NONOS AT firmware's passive TCP
receive path in multiple-connection mode. It sends eight 1537-byte binary
payloads, leaves responses buffered in the modem during GC and a delay, then
pulls them in requests of at most 257 bytes and checks every byte. The parser
expects the NONOS format `+CIPRECVDATA,<length>:<payload>`; this differs from
newer ESP-AT releases. Notifications use `+IPD,<id>,<length>` without payload.
Initialization selects `CIPMODE=0` before enabling `CIPMUX=1`; the installed
firmware rejects `CIPMODE` commands while multiple-connection mode is active.

Build it with the same application package root as above, preserve its binary,
and run `../pio-lifecycle.py` with `--expect 'RP2040 ESP8285 passive TCP: PASS'`,
`--uploader`, `--port`, `--id`, `--image` and `--restore-image`. The restore image
must be an ordinary VM smoke application. The helper Wi-Fi echo service must
already be running. This fixture checks buffered reads, not full-window TCP
backpressure or a production network adapter.

`network.toit` uses `cellular.modules.espressif.esp8285.Esp8285` through its
`net.Interface` API. It verifies the assigned address and local socket ports,
three 3001-byte TCP echoes, and eight 512-byte UDP echoes for each of an
ephemeral port and explicit port 41000. UDP sender metadata and all payload
bytes are checked; transfers include GC. Use `pio-lifecycle.py` as above with
`--expect 'RP2040 ESP8285 network adapter: PASS'`.

`udp-bind.toit` is the retained diagnostic for NONOS UDP binding behavior.
Its output shows that explicit local port zero is rejected, while omitting
optional local-port parameters requests an ephemeral port. It reports results
for a fixed matrix and ends with `RP2040 ESP8285 UDP bind probe: DONE`; this
diagnostic marker alone does not establish data-transfer correctness.

`network-stress.toit` uses the helper's DNS server on UDP port 53 and its
autonomous TCP sender on port 4243. The helper resolves only `echo.rp2040.test`
and `burst.rp2040.test`; other names receive NXDOMAIN. No upstream DNS is used.
The client sets this resolver with the adapter's volatile `--dns-server`
option. Each of three interface open/close cycles checks DNS, delays TCP reads
while 65,537 bytes are sent, and exchanges 32 UDP datagrams concurrently. All
payload bytes and UDP sender metadata are checked, with GC during TCP reads.
Run with `--expect 'RP2040 ESP8285 network stress: PASS' --timeout 180`.
This passed three cycles on Pico W-2023 with NONOS AT 1.7.6.0. The initial run
exposed premature EOF: NONOS reports `CLOSED` while unread passive TCP bytes
remain. The adapter now drains them before returning EOF.

`dns-probe.toit` logs volatile DNS settings and measures positive/negative
lookup latency with a 60-second observation window per command. It ends with
`RP2040 ESP8285 DNS probe: DONE`; inspect individual results before drawing
conclusions. The helper's DNS packet fixture can be checked without hardware:

```sh
build/host/sdk/bin/toit run tests/hw/rp2040/modem/dns-fixture-test.toit
```

`passive-close.toit` isolates that modem behavior using the shared AT session
directly. It records when `CLOSED` arrives, continues pulling buffered bytes,
and reports the final count and pending lengths. On the tested firmware,
`CLOSED` arrived after 62,432 consumed bytes; reads still recovered all 65,537
bytes before an acknowledged `ERROR` indicated the exhausted link. Its `DONE`
marker is diagnostic; the adapter stress fixture supplies the pass assertions.

`network-service.toit` exercises `Esp8285ServiceProvider` through the standard
network service. It checks shared clients, DNS/TCP/UDP over RPC, UART release
after the last network client, and cleanup after a separate client process
exits with resources open. Run with
`--expect 'RP2040 ESP8285 network service: PASS' --timeout 180`.

`tls.toit` wraps the adapter's TCP socket in the SDK TLS implementation. The
helper serves TLS on port 4244 using the shared test certificate. Its ESP32
firmware must enable `CONFIG_MBEDTLS_TLS_SERVER_AND_CLIENT`; client-only builds
cannot run this fixture. The Pico sets its software wall clock explicitly and
checks valid connections before and after wrong-host, untrusted-root and expired
certificate cases. Positive cases check 11,554 echoed bytes with concurrent GC.
Run with `--expect 'RP2040 ESP8285 TLS: PASS' --timeout 360`. This passed on
Pico W-2023 with the helper's default 10-second handshake deadline: authenticated
handshakes took 3.59 and 3.65 seconds. The test exposed two issues: missing
mbedTLS NIST-prime optimizations made verification exceed the peer deadline,
and NONOS sometimes acknowledges empty passive reads with bare `OK`. The
adapter now waits for later data after such a reply instead of rejecting it.

`service-containers.py` builds an envelope with separate provider, client and
coordinator containers. Only the coordinator starts at boot; it starts the
other installed images through `system.containers`. Three repetitions of four
cycles check shared
network clients, process exit with TCP/UDP/network resources open, forced
termination during a blocked TCP read, and a fresh client afterward. Each
cycle checks provider open/close counts and reacquires the UART after cleanup.
The extended twelve-cycle run passes with the Pico page-aware allocator. It
previously exposed newlib heap fragmentation despite substantial free memory;
see the investigation handoff below. It uses bundled images without modifying the
persistent container registry or storage fixtures.

```sh
TOIT_PACKAGE_CACHE_PATHS="$PWD/tools/.packages-bootstrap" \
python3 tests/hw/rp2040/modem/service-containers.py \
  --toit build/host/sdk/bin/toit \
  --envelope build/rp2040-pico_w_2023-envelope/firmware.envelope \
  --output build/rp2040-w2023-vm/service-containers \
  --port "$PICO_PORT" --id "$PICO_ID" --restore-image "$SMOKE_IMAGE"
```

Use the observed persistent USB path for `PICO_PORT`, its verified board ID for
`PICO_ID`, and a known passing ordinary VM smoke binary for `SMOKE_IMAGE`.
Add `--build-only` to prepare the images without accessing hardware. The helper
Wi-Fi fixture must already be running. Hardware execution restores the smoke
image in a `finally` block.

`firmware-download.py --http-only` runs `http-download.toit` against the same
image bytes and helper compression, without flash writes or service RPC. It
checks the truncated body, hashes the full corrupt and valid bodies, and reports
UART errors and stalled byte counts. Both boards are restored afterward. The
optional `--diagnose-helper-memory` enables a sender GC probe and changes timing;
keep its result separate from normal acceptance runs.

`firmware-download.py` builds two different application images and serves the
target image over HTTP from the helper ESP32. The downloader first rejects a
truncated response and a complete image with the wrong SHA-256, then commits the
valid image through `system.firmware`. The booted target verifies its own digest
and checks that it differs from the downloader image. The host also checks the
installed version, image size and CRC reported by the recovery loader.

```sh
TOIT_PACKAGE_CACHE_PATHS="$PWD/tools/.packages-bootstrap" \
python3 tests/hw/rp2040/modem/firmware-download.py \
  --toit build/host/sdk/bin/toit \
  --envelope build/rp2040-pico_w_2023-envelope/firmware.envelope \
  --output build/rp2040-w2023-vm/network-ota \
  --jag build/pio-jag/jag \
  --port "$PICO_PORT" --id "$PICO_ID" --restore-image "$SMOKE_IMAGE"
```

The helper defaults to `pico-w-helper`; override with `--helper`. This runner
deploys its HTTP asset to the helper and restores the ordinary Wi-Fi fixture
and Pico smoke image afterward. Run only one hardware runner at a time.
`--build-only` prepares both images without accessing either board.
The asset uses dynamic Huffman gzip coding and a 1 KiB history. This exercises
helper memory pressure while serving the image. `--gzip-strategy fixed` selects
a comparison control; both options decompress to identical HTTP response bytes.
The helper needs the SDK native allocation-failure notification as well as the
TCP/UDP GC-event library fixes: lwIP timer failures can otherwise leave a sender
blocked without requesting GC. The allocation hook records a flag; pending TCP
polls wake Toit to collect outside the hook.

Changed-image Wi-Fi OTA passed with dynamic coding and the plain helper fix:
truncated and corrupt images were rejected, the valid 606,212-byte image booted
and verified its SHA-256, and both boards were restored. The diagnostic run also
exercised allocation notifications while `tcp_output` returned success. Earlier
fixed-coding, stress, TLS and network-service checks passed too. The separate
container regression passes all twelve lifecycle cycles with the page-aware
Pico allocator. Historical intermittent USB recovery loss is still under
investigation; arbitrary interrupted AT payloads still require transport
resynchronization. See the
[investigation handoff](../../../../docs/rp2040-esp8285-wifi-investigation.md)
for exact versions, artifacts and the remaining readiness gates.

## Download isolation fixtures

`network-paced.toit` validates 602,116 deterministic bytes in each of three
independent connections. Its helper is `paced-peer-esp32.toit`, which replaces
the ordinary Wi-Fi fixture during this test. Port 4243 sends continuously;
4246 pauses 300 ms after each 2 KiB; 4247 pauses 600 ms after each 4 KiB.
Run the Pico image with `pio-lifecycle.py`, using
`--expect 'RP2040 ESP8285 paced TCP: PASS' --timeout 400`, then restore the
ordinary helper fixture. Each pattern passed individually with the original
driver, before adding its lost-notification polling fallback. All received
602,116 bytes with zero UART errors. These comparisons do not prove that all
sender pacing or packetization patterns are safe.

`http-download.toit` receives the same truncated, corrupt and valid HTTP bodies
as the OTA test, but uses the adapter directly and hashes bytes without writing
flash. It logs the UART error counter at each request and during stalls.
Build the OTA assets with `firmware-download.py --build-only`, then compile
this source and install its snapshot into the base envelope with
`--trigger boot --assets OUTPUT/download-assets.bin`. Deploy the ordinary
helper with `jag run --assets OUTPUT/helper-assets.bin`. Run the extracted Pico
image with `pio-lifecycle.py`, using
`--expect 'RP2040 ESP8285 HTTP download: PASS' --timeout 410`. Restore the
ordinary helper without assets afterward, including on failure.

The original-driver HTTP comparison reproduced the stall without firmware
writes, service RPC or forced GC: the second body stopped at 6,784 bytes with
zero UART errors. See [the investigation handoff](../../../../docs/rp2040-esp8285-wifi-investigation.md)
for logs, controlled driver versions and subsequent results. Treat this as a
reproducer, not a passing regression test.

The helper supports three optional asset controls for this investigation:

- `firmware-window`: decimal gzip history size, default `32768`. The firmware
  runner uses a 1 KiB window and supplies `1024` here
  to reduce the helper's decoder workload and live memory requirement. The
  decompressed firmware is unchanged.
- `firmware-pattern`: substitutes generated bytes `(offset * 31 + 19) & 0xff`
  for inflation, preserving the HTTP framing and requested body size. For the
  direct HTTP client, also supply the SHA-256 of those generated bytes in its
  download assets. This control passed both complete 602,116-byte responses.
- `firmware-memory-probe`: enables an observer which collects garbage after
  ten seconds without sender progress and logs free memory before and after.
  This changes the execution being measured; leave it absent for validation.

`nonos-receive-test.py` is a host diagnostic for the installed modem SDK's
passive receive callback. It extracts the callback and `pbuf_free` from a local
Espressif NONOS SDK checkout, builds them with transport stubs and AddressSanitizer,
and exercises a two-buffer chain. It requires the original code to exhibit a
use-after-free, then checks that copying before freeing preserves both payloads:

```sh
python3 tests/hw/rp2040/modem/nonos-receive-test.py \
  --sdk /path/to/ESP8266_NONOS_SDK \
  --output build/nonos-receive-source
```

The reviewed SDK commit is `8e1386548cdca53f24e4758b5fc8494791ee060b`.
This test neither downloads nor flashes firmware. Its passing result establishes
the source defect and the limited chain-copy correction; it does not establish
the cause of the hardware stall or validate a replacement modem image.

`../tcp-gc-esp32.toit` tests the helper SDK's lwIP GC event handling using real
loopback TCP sockets. It injects the GC readiness bit before writes and reads,
checks that the bit is consumed, and verifies all transferred bytes over three
rounds. This covers a notification whose global GC request was already handled
by another socket; it does not inject native allocation failure. Run it with
Jaguar on the helper and expect `RP2040 helper TCP GC event: PASS`, then restore
`../wifi-peer-esp32.toit`. Do not run it on the ordinary host TCP backend, whose
GC primitive intentionally aborts. The fixture has a five-second test deadline.
On the helper ESP32, the original SDK library timed out on the first write;
the corrected library passed all three rounds. Logs and both compiled snapshots
are retained locally under `build/rp2040-w2023-vm/tcp-gc-event/`.

`send-abort-probe.toit` characterizes NONOS AT 1.7.6.0 send cancellation and
UART framing. It checks TCP/UDP cancellation at four partial-payload boundaries,
subsequent clean echoes, rejection of literal `+++`, and corruption of a split
CIPSENDEX escape. Its PASS means those **defects were reproduced**, not that the
modem is binary-transparent. Run with the marker
`RP2040 ESP8285 send abort probe: PASS` and a 110-second observation timeout.
All traffic goes to the isolated echo peer; emergency filler is test-only.

`sendex-probe.toit` checks continuous CIPSENDEX binary encoding. It does not
cover interruption or split escape characters; use the framing probe above.
Its marker is `RP2040 ESP8285 sendex probe: PASS`.

`send-canceled.toit` exercises the adapter's handling of the modem's completed
`SEND Canceled` response. TCP and UDP failures must return promptly and allow
subsequent correct traffic on both existing sockets. Run with the marker
`RP2040 ESP8285 send canceled handling: PASS` and a 50-second timeout.

`at2-probe.toit` is the acceptance fixture for the newer ESP-AT 2.2 candidate.
The first hardware run failed on a literal TCP `+++` payload with
`SEND Canceled`. After a normal power-cycle, passive TCP and single UDP echoes
passed, but two queued datagrams of 97 and 211 bytes returned as one 308-byte
response. On October 6, the split-escape check passed on TCP and UDP. The larger
queued pair timed out during CIPSEND, before either receive check, and left the
modem unresponsive to AT and AT+RST. It
requires AT version 2.x, tests literal `+++` and binary echoes, forces a split
CIPSENDEX escape, and checks modern passive TCP/UDP data with sender metadata.
It also queues two UDP echoes before reading, using `CIPRECVLEN` as a barrier,
and checks their individual lengths and bytes with a 1,460-byte read limit.
The pairs are 97/211 and 1,009/907 bytes, covering concatenation and truncation
across a datagram boundary. This barrier assumes the candidate's aggregate
queued-length semantics; a timeout alone does not prove corruption. The AT 2.2
source/disassembly audit predicted this boundary loss. Firmware with
first-datagram length semantics needs a different queue
barrier before using this test.
The expected marker is `RP2040 ESP8285 AT2 acceptance: PASS`. Do not substitute
compilation or the passing GMR check for evidence that the firmware fixes the
defects. An optional `at2-test` asset selects `passive` (single echoes and queued
UDP), `queued` (both queued UDP pairs), `queued-large` (the second pair only),
`sendex` (split escape only), or `sendex-binary` (escaped binary payloads and
split escape). The last selection escapes plus signs and backslashes and
forces three-byte UART writes separated by flushes and 3 ms pauses. It is a
diagnostic, not an adapter implementation. After a normal power-cycle its
binary TCP and UDP checks passed, including 1,460-byte all-plus and all-backslash
payloads. The `queued-large-escaped` selection uses that send path for the large
queued pair; it confirmed loss of the final 456 bytes after a merged 1,460-byte
read, with zero Pico UART errors and an acknowledged reset. The default `all` runs
full acceptance with ordinary CIPSEND.
Subset markers include the selection and do not certify full acceptance.
Failure cleanup no longer sends filler bytes. It attempts an acknowledged
ordinary reset only while the AT session remains open. If AT stops responding,
check ROM SYNC through the native bridge before requesting a power-cycle (see
below). Checks throw exceptions instead of using
`expect`, whose process exit bypasses cleanup. Setup queries CIPMUX before
closing stale connections, since CIPCLOSE=5 is invalid in single mode.

`../reset-esp32.toit` pulses the verified helper GPIO21-to-Pico RUN connection
using open drain and leaves GPIO4-to-GP17 biased high. It resets only the Pico;
the modem's reset pin is not connected. Restore `../wifi-peer-esp32.toit` after
using it. On October 6 this recovered USB update access after a silent serial
connection; the cause of that loss of response remains unestablished.

`udp-extension-probe.toit` tests the experimental `+TOITUDP` receive command in
`tools/rp2040/esp-at/udp-receive.c`. This requires a different modem image; it
does not work with stock ESP-AT. The helper supplies six datagrams from ports
4246 and 4247: 1,009, 907, zero, 1,460, 1,461 and three bytes. The probe verifies
packet boundaries, sender metadata, empty versus unavailable data, oversized
discard, and two bursts per socket over two open/close cycles. The second burst
checks reception after draining the socket without resetting AT notification
state. Success is reported only after UART/session cleanup. The approved image
was flashed at 0x20000 on October 6 after a full backup; modem settings and both
bootloaders were preserved. The initial version with one burst per socket passed
in application 337 with zero UART errors; smoke restore 338 also passed.
The strengthened two-burst fixture passed in application 339, again with zero
UART errors; smoke restore 340 passed. Its log and exact source/image are under
`build/rp2040-w2023-vm/udp-extension-reuse/`.

`network-binary.toit` exercises the same behavior through the public cellular
network API, plus binary TCP/UDP sends (`+++`, control-looking data, all byte
values and maximum-size escape expansion). It requires extension version 2 for
its empty UDP send case. The prior version-1 run passed the nonempty send cases,
then timed out on an acknowledged empty CIPSENDEX send; explicit zero-length
CIPSEND also returned ERROR. Version 2 adds `+TOITUDPEMPTY`; it was installed
after approval and the full fixture passed in application 348 with zero UART
errors. Smoke restore 349 passed. Evidence is under
`build/rp2040-w2023-vm/at2-adapter-binary-v2/`. Its build instructions and pinned patch are in
`tools/rp2040/esp-at/README.md`. The full fixture's marker is
`RP2040 ESP8285 adapter binary: PASS`; partial send-case markers do not prove
empty transmission or the later queued-boundary tests passed.

`interrupted-send.toit` pauses a real CIPSENDEX payload after exactly seven
bytes, then tests caller cancellation and a deadline. It checks that the
interface closes, a blocked reader wakes, and a subsequent API call emits no
commands into the unfinished payload. After the receive task has stopped, the
fixture explicitly terminates that known payload, consumes its acknowledgement,
and reconnects for a TCP echo. This cleanup relies on a known byte boundary;
it does not establish automatic recovery from arbitrary interrupted sends.
Run it with `../pio-lifecycle.py`, expecting
`RP2040 ESP8285 interrupted send: PASS`, and retain its exact image and log.
Both cases passed in application 383, with zero UART errors; smoke restore 384
passed. Evidence: `build/rp2040-w2023-vm/at2-empty-read-fixed/interrupted-send-fixed/`.

The extension requires passive receive mode. `AT+TOITUDP?` returns version and
MTU as `+TOITUDP:2,1460`. `AT+TOITUDP=<link-id>` returns one packet as
`+TOITUDP:<length>,"<ip>",<port>,<binary payload>`, followed by CRLF and OK.
An empty packet has length zero and still includes sender metadata. An empty
queue returns `+TOITUDP:-1`; an oversized packet is consumed and returns
`+TOITUDP:-2`. These status lines are followed by OK. Invalid parameters or
non-UDP sockets return ERROR. The extension does not update the stock AT
notification bookkeeping, so a future adapter must poll while waiting for UDP;
it cannot rely solely on successive +IPD notifications.

The native host harness is under `esp-at/`; compile it with the extension using
`-DTOIT_AT_HOST_TEST -Itests/hw/rp2040/modem/esp-at` and sanitizer flags. It uses
real loopback sockets and covers both queued pairs, mixed sender ports, empty
packets, MTU/oversized packets, invalid arguments/sockets and short UART writes.
Those tests do not substitute for the lwIP/AT-core hardware acceptance above.

After the initial fixture failed and acknowledged AT+RST, the modem returned
valid ROM SYNC replies but no AT replies. The native bridge and esptool v1 RAM
stub restarted the installed application without a physical power-cycle or
flash write. With the native bridge installed and modem confirmed in download
mode, use:

```sh
python3 tools/rp2040/inspect-modem.py \
  --port /dev/serial/by-id/usb-Raspberry_Pi_Pico_50443405886E0B1C-if00 \
  --id 50443405886E0B1C --start-application
```

This cannot reset a hung modem or resynchronize an interrupted AT payload.
The modem's hardware reset remains unwired. The observed ROM mode explains this
specific AT timeout; it does not retrospectively explain earlier failures.

`../udp-gc-esp32.toit` complements the TCP GC fixture. It injects the cached UDP
GC readiness bit before loopback sends and receives, validates three 513-byte
round trips, and requires the bit to be consumed. The missing UDP correction
from [Toit PR #3266](https://github.com/toitlang/toit/pull/3266) passes on the
helper; the ordinary Wi-Fi fixture was restored and reported ready. Evidence:
`build/rp2040-w2023-vm/udp-gc-event/`. This tests event consumption rather than
native allocation-failure injection.


## USB recovery after modem timeout

`recovery-timeout.toit` waits for the idle runner's `fail` command, checks the
binary TCP/UDP payloads using the current adapter, and deliberately times out a
UDP receive with no pending echo. It closes the network and UART, verifies the
exact deadline error, then throws `USB_RECOVERY_AFTER_MODEM_TIMEOUT`.

Build it into an application envelope as for the other modem fixtures. With
the ordinary helper running, pass its binary as `--exception-image` to
`../recovery-idle.py`, using an ordinary smoke binary as `--idle-image`. Add
`--exception-timeout 90` and
`--exception-marker 'RP2040 modem recovery: DEADLINE_EXCEEDED'` so an unrelated
initialization failure cannot count as the intended timeout. For the idle
case use `--cycles 1 --delays 180 --port-state closed` and a new output directory.
The runner preserves the first failed state rather than retrying an upload or
pulsing recovery GPIOs. Archived adapter images may reject newer modem firmware
before traffic; decode their exception before treating them as reproductions.

The current-adapter three-minute closed-port case passed: all binary payloads,
the exact deadline marker, all three USB uploads and the final smoke image were
verified. This adds recovery coverage; the earlier intermittent USB loss has
not been explained or declared fixed.
