// Tests the EC618 hardware watchdog (lib/ec618/watchdog.toit) end to end.
//
// The watchdog guards against a hung (busy) device, so the test keeps the CPU
// busy rather than sleeping: the EC618 gates the watchdog clock in deep sleep,
// so a sleeping device would never trip it.
//
// Self-verifying across the reset it induces, using a flash-backed state byte.
// The EC618 main WDT reset is reported as a power-on (the chip has no AP-side
// watchdog interrupt to record a reason), so the test does NOT rely on the
// reset reason; instead it detects that the device was reset *while hanging*:
//
//   Fresh boot (state 0): arm a watchdog, feed it for longer than the timeout
//     while busy (proving feeding keeps the device alive), write state=1, then
//     stop feeding and busy-loop. The watchdog must reset the device. If the
//     loop instead runs to completion, write state=2 (watchdog failed to fire).
//   Boot with state 1: we were reset during the hang => the watchdog fired.
//     Report PASS (and print the reset reason for information).
//   Boot with state 2: the hang completed without a reset => FAIL.
//
// Re-runnable: each terminal case resets the state, so a power cycle repeats it.
//
// Use with:
//   toit tool firmware -e <envelope> container install --trigger=boot \
//       watchdog watchdog.snapshot

import ec618
import ec618.watchdog
import system.storage

TIMEOUT-S ::= 3
STATE-KEY ::= "state"

main:
  reason := ec618.reset-reason
  print "[watchdog-test] last reset: $(ec618.reset-reason-name reason)"

  bucket := storage.Bucket.open --flash "test/watchdog"
  state := ((bucket.get STATE-KEY) or #[0])[0]

  if state == 1:
    // We wrote state=1, started hanging, and were reset before clearing it,
    // so the watchdog reset the device mid-hang.
    print "[watchdog-test] WATCHDOG TEST PASSED: device was reset while hung"
    print "[watchdog-test]   reset reason: $(ec618.reset-reason-name reason) (the EC618 main WDT reset reads as power-on)"
    bucket[STATE-KEY] = #[0]  // Re-arm for a re-run on the next power cycle.
    bucket.close
    return

  if state == 2:
    print "[watchdog-test] WATCHDOG TEST FAILED: the previous hang completed without a reset"
    bucket[STATE-KEY] = #[0]
    bucket.close
    return

  // Fresh boot: arm, prove feeding keeps us alive, then hang.
  print "[watchdog-test] arming watchdog with a $(TIMEOUT-S)s timeout"
  watchdog.watchdog-start --timeout=(Duration --s=TIMEOUT-S)

  // Feed while busy, for longer than the timeout, to prove the device stays
  // alive as long as it is fed.
  6.repeat:
    busy-wait --ms=1000
    watchdog.watchdog-feed
    print "[watchdog-test] fed, alive at $(it + 1)s (> $(TIMEOUT-S)s timeout)"

  // Record that we are about to hang (persisted to flash immediately).
  bucket[STATE-KEY] = #[1]

  print "[watchdog-test] simulating a hang (busy, no feed); expect a reset shortly"
  start-us := Time.monotonic-us
  bound-us := (4 * TIMEOUT-S) * 1_000_000
  while (Time.monotonic-us - start-us) < bound-us:
    busy-wait --ms=1000
    print "[watchdog-test] hung for $((Time.monotonic-us - start-us) / 1_000_000)s (no feed) ..."

  // Only reached if the watchdog never reset us.
  watchdog.watchdog-stop
  bucket[STATE-KEY] = #[2]
  bucket.close
  print "[watchdog-test] WATCHDOG DID NOT FIRE within $(4 * TIMEOUT-S)s of a busy no-feed loop"

// Busy-waits about $ms milliseconds, keeping the CPU active so the device does
// not enter deep sleep (which would gate the watchdog clock).
busy-wait --ms/int -> none:
  deadline := Time.monotonic-us + ms * 1000
  while Time.monotonic-us < deadline:
    null  // Spin.
