# Feedback on the ESP8285 Wi-Fi stall investigation

Review of `rp2040-esp8285-wifi-investigation.md`, the cellular driver, the
fixtures and the recorded logs, as of 2026-09-30. Nothing in this document was
tested on hardware; it is analysis of existing evidence plus suggested next
steps.

## Code review

The production code is in good shape. The experimental changes listed as
reverted are in fact reverted, and the adapter and AT session changes are
coherent and covered by host tests. Items to fix or clean up eventually:

1. **Fixture diagnostics still change timing.** DEBUG provider logging, the
   per-chunk before/after write prints, the helper's one-second phase ticker
   and the helper's 1 KiB inflation batching all remain. Remove them before
   declaring any result final.
2. **Misleading log text in the AT session.** In `run_`, the receive loop logs
   "(unhandled)" precisely when the callback did handle the line.
3. **The TCP reader has no poll fallback.** `TcpSocket_.read_` waits on a
   readable flag that only a `+IPD` notification sets. One lost notification
   blocks the reader until the caller's deadline. AT modems drop unsolicited
   lines; a periodic re-check while a read is pending is standard practice
   and would be worth adding independently of this bug.
4. **Flash writes run with interrupts disabled.** `firmware_rp2040.cc` wraps
   erase and program in `save_and_disable_interrupts`, which XIP flash needs.
   The modem UART is interrupt driven with a 32-byte hardware FIFO, so any
   unsolicited modem output longer than that during a sector erase is lost.
   Writes block until the worker finishes, so a `+CIPRECVDATA` response cannot
   be corrupted, but a `+IPD` line can be eaten. The UART driver counts
   overruns; nothing reads that counter during a stall. Check it.

## The stall: a clue in the existing evidence

The helper's native TCP snapshot pins down where the missing bytes are:

| Quantity | Value |
| --- | --- |
| Peer window seen by the helper | 40 |
| NONOS lwIP receive window, also the documented passive buffer size | 2920 |
| ESP-IDF default TCP MSS | 1440 |
| 2920 minus two full segments | 40 |

So the modem's TCP stack has two full segments charged against its receive
window that its AT layer no longer reports in `CIPRECVLEN`. The modem will not
re-open the window until it accounts for those bytes. In the lwIP generation
used by NONOS, data the application layer could not take is only re-delivered
when the next segment arrives on that connection. The helper cannot fit a
segment into a 40-byte window, so both sides wait. What moves things is the
helper's persist timer, which sends window-sized pieces at exponential backoff
up to a minute apart. That is the "slow progress with the window creeping up"
you observed, and it is why every read-size, NODELAY and reset variation left
the behavior unchanged.

Every stall log shows the same trigger. The last successful read is a partial
one (128, 256, 257 bytes), then an empty `OK`, then silence. The Pico drained
the modem buffer to empty while the sender was still mid-stream and
window-limited. In the passing burst test the sender always outruns the UART,
so the buffer never drains before the end of the transfer. In the HTTP fixture
the helper is slow and bursty: it inflates gzip 1 KiB at a time while sharing
the CPU with the ticker and feeder tasks. The 256-byte read immediately after
the headers in every run shows the reader catching the sender right away.
Sender pacing is the one factor that differs between the passing and failing
paths and fits all the evidence.

## Suggested next steps, in order

1. **One-factor reproduction on the passing path.** Keep the raw burst
   fixture: no HTTP, no firmware writes, no provider container. Make the
   helper sleep a few hundred milliseconds every few KiB while sending the
   full image size, with the Pico reading and discarding continuously. If
   this stalls, HTTP, flash and containers are ruled out in one run.
2. **Get ground truth rather than stack introspection.** A laptop in monitor
   mode on the helper's channel can decrypt the traffic in Wireshark, since
   the WPA2 credentials are public fixture values. That shows the modem's
   advertised window in its own ACKs and settles whether the modem or the
   helper is misbehaving.
3. **Read the UART overrun counter during a stall** to close out the
   lost-notification hypothesis for good.
4. **Evaluate active receive mode.** With `CIPRECVMODE=0` the modem returns
   its window immediately and the Pico buffers in RAM, of which it has plenty.
   The driver already has the bounded-queue pattern for UDP. Passive mode on
   NONOS 1.7 has a poor track record, and this may be the pragmatic fix if
   step 1 confirms the trigger.

Treat any driver-side change as provisional until the full OTA scenario and
the earlier stress, TLS and lifecycle tests pass together.
