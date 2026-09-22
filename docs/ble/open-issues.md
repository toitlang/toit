# Open issues

Failures observed on the rig that are not understood, and what to do about
each. The detailed campaign records are archived outside the repository
(`opentoit-ble-archive/docs-2026-09-22`).

## Immediate bond resumption against a BlueZ peripheral (resolved 2026-09-23)

A Toit central that reconnected to a bonded BlueZ 5.87 peripheral and started
encryption right after Connection Complete was disconnected by the peer
(remote reason 0x13) before Encryption Change. The previous investigation
attributed this to a Linux kernel bug and prepared a patched `bluetooth.ko`.

Three things on our side were nonstandard, each fixed:

1. The host never issued LE Read Remote Features. Connection setup now includes
   the exchange; `Central.connect` returns after it completes.
2. Security ran before any ATT traffic. A GATT client exchanges its MTU first
   (Core Vol 3 Part G 4.3.1); the peer's ATT response also proves that its
   host finished connection setup. The central provider now exchanges the MTU
   before running the security owner.
3. BlueZ holds the ATT channel of a bonded peer until the link is encrypted and
   sends a Security Request instead. The resumption owner answered Pairing Not
   Supported. It now follows Core Vol 3 Part H 2.4.6, Figure 2.7: a stored key
   that meets the request starts encryption immediately (from the ATT receive
   task, concurrently with the pending MTU exchange), a request for MITM that
   an unauthenticated key cannot meet is answered Pairing Not Supported, and a
   request during or after encryption setup is ignored.

With the reference presenting a Just Works peer (an agent registered as
NoInputNoOutput, so BlueZ requests 0x29 rather than 0x2d), pairing and
immediate resumption both pass on unmodified kernel 7.2.4:
`build/ble-resume-features-001/{pair,resume}`. A BlueZ peripheral without an
agent asks for MITM; resuming a Just Works bond against it requires
authenticated re-pairing, which is a different scenario.

## Intermittent connection failure with reason 0x3e (attributed 2026-09-23)

Linux (Realtek dongle) central reconnecting to an ESP32 peripheral fails at
random cycles with disconnect reason 0x3e, Connection Failed to be
Established, before any host traffic. The discriminating experiment
(`build/ble-0x3e-ab-001`): the same central, dongle and script against a
NimBLE peripheral on the same board type fails identically, on the third
connection in that run, and against the Toit-host peripheral on the tenth. The
failure is therefore in the link layer between the Realtek controller and the
ESP32 controller, not in the Toit host.

Host consequences: `Central.connect` now reports the loss as
`ConnectionLost` with the controller reason so callers can distinguish it, and
an application that needs the connection retries. A non-Realtek central (the
laptop, the Raspberry Pi, or an nRF52840 running Zephyr's HCI USB sample) is
the way to measure whether the ESP32 side contributes; reconnect campaigns on
this dongle are not a host reliability gate.

## Encryption failing with MIC error (status 0x3d)

Authenticated revocation campaigns saw LE Start Encryption fail with status
0x3d twice, then a disconnect with 0x3e. A 30-second start lead for the peer
made later runs pass. Status 0x3d means the two sides used different LTKs.
This is a bond storage or revocation ordering bug, not timing. Reproduce with
HCI traces on both ends (see Tracing below) and compare the LTKs each side
installed.

## Fixture-side compensations to revisit

Each of these routes a test around a failure instead of explaining it:

- `hci-connect` uses a one-second dwell after connect; without it advertising disappears after short connections.
- The pairing-retry test peer keeps its controller running after rejecting pairing so the Pairing Failed drain succeeds.
- A fresh static random identity was used to sidestep an Authentication Failure (reason 5) in the central service probe.
- The BlueZ migration test retries discovery to absorb a second Service Changed indication.
- `Central --early-acl-timeout` buffers ACL that arrives before Connection Complete on USB dongles. This is plausible (separate USB endpoints) but was never captured; keep it only after a capture shows the reorder.
- The credit drain before aborting a link, added so a generated Pairing Failed reaches the peer, is a best-effort mitigation.

## Dropped

- Android status 133 on the original ESP32 fails with NimBLE too; it is not a host issue.
- Heap-exhaustion recovery is best effort by decision; the extra machinery added for it can be removed.

## Tracing

The missing tool behind all of the above is a packet trace from both ends. Add
a btsnoop writer to the Toit transport (`Transport` wrapper writing
`btsnoop` format so Wireshark opens it) and use `btmon` on the Linux side.
Then rerun the three failures above with traces instead of A/B guessing.
