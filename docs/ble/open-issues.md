# Open issues

Failures observed on the rig that are not understood, and what to do about
each. The detailed campaign records are archived outside the repository
(`opentoit-ble-archive/docs-2026-09-22`).

## Immediate bond resumption against a BlueZ peripheral fails

A Toit central that reconnects to a bonded BlueZ 5.87 peripheral and starts
encryption right after Connection Complete is disconnected by the peer (remote
reason 0x13) before Encryption Change. Waiting for the peer's Security Request,
or a one-second delay, makes it pass. The previous investigation attributed this
to a callback-selection bug in the Linux kernel's HCI request handling and
prepared a patched `bluetooth.ko`; that patch was never loaded.

The practical cause is on our side: the host never issues LE Read Remote
Features. Every mainstream host does after connection and before starting
encryption, which lets the peripheral's kernel finish its own feature request
before the LTK reply arrives. Fix: issue LE Read Remote Features (0x2016) as
part of connection setup and wait for LE Read Remote Features Complete before
starting encryption. Validate with `tests/ble-hardware/central-fresh-bond.toit`
against an unmodified kernel.

## Intermittent connection failure with reason 0x3e

Linux (Realtek dongle) central reconnecting to an ESP32 peripheral fails at
random cycles (5, 18, 78, 80, 274, 289 in different runs) with
disconnect reason 0x3e, Connection Failed to be Established, about 250 ms into
discovery. The peripheral times out in accept. Changing adapter, native
firmware, or keeping the controller alive did not change the picture. Zero host
ACL had been sent on a failing attempt.

0x3e is a link-layer establishment failure and happens before the host is
involved. The discriminating experiment has not been run: same board, same
dongle, same script, with NimBLE peripheral firmware. If NimBLE fails at the
same rate the cause is controller or RF and the host only needs a clean retry
policy in the central and continued advertising in the peripheral. Also test
with a non-Realtek central once one is available.

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
