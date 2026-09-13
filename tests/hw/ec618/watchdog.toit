// Tests the EC618 application watchdog (lib/ec618/watchdog.toit) end to end.
//
// The user deadline is enforced by a high-priority task whose timed wait wakes
// the chip from tickless idle. The normal WDT is its active-time backstop if a
// busy lockup starves that task. This test verifies the observable deadline
// during both application sleep and busy execution.
//
// Self-verifying across the reset it induces, using a flash-backed state byte.
// Watchdog resets can be reported as power-on, so the test does not rely on the
// reset reason. It records each armed phase before waiting for its reset:
//
//   State 0: feed across short sleeps for longer than the timeout, then record
//     state 1 and sleep without feeding. The deadline must wake/reset the chip.
//   State 1: the idle deadline passed. Feed across busy intervals, then record
//     state 2 and stay busy without feeding. The deadline must reset the chip.
//   State 2: both reset phases passed; report PASS and clear the state.
//   State 0x81/0x82: the corresponding no-feed phase outlived its bound; FAIL.
//
// Re-runnable: each terminal case resets the state, so a power cycle repeats it.
//
// Use with:
//   toit tool firmware -e <envelope> container install --trigger=boot \
//       watchdog watchdog.snapshot

import ec618
import ec618.watchdog
import system.storage

TIMEOUT-S ::= 2
STATE-KEY ::= "state"

main:
  reason := ec618.reset-reason
  print "[watchdog-test] last reset: $(ec618.reset-reason-name reason)"

  bucket := storage.Bucket.open --flash "test/watchdog"
  state := ((bucket.get STATE-KEY) or #[0])[0]

  if state == 2:
    print "[watchdog-test] WATCHDOG TEST PASSED: idle and busy no-feed deadlines both reset the device"
    print "[watchdog-test]   final reset reason: $(ec618.reset-reason-name reason)"
    bucket[STATE-KEY] = #[0]  // Re-arm for a re-run on the next power cycle.
    bucket.close
    return

  if state == 0x81 or state == 0x82:
    phase := state == 0x81 ? "idle" : "busy"
    print "[watchdog-test] WATCHDOG TEST FAILED: the $phase no-feed phase completed without a reset"
    bucket[STATE-KEY] = #[0]
    bucket.close
    return

  if state == 1:
    print "[watchdog-test] idle/light-sleep deadline passed; testing busy execution"
    watchdog.watchdog-start --timeout=(Duration --s=TIMEOUT-S)

    // Feed while busy for longer than the timeout.
    5.repeat:
      busy-wait --ms=1000
      watchdog.watchdog-feed
      print "[watchdog-test] busy feed, alive at $(it + 1)s"

    bucket[STATE-KEY] = #[2]
    print "[watchdog-test] busy without feed; expect a reset within $(TIMEOUT-S)s"
    wait-bound --busy

    watchdog.watchdog-stop
    bucket[STATE-KEY] = #[0x82]
    bucket.close
    print "[watchdog-test] busy deadline did not fire"
    return

  // Fresh run: prove that sleeps shorter than the deadline preserve the
  // remaining wall-clock deadline when it is fed.
  print "[watchdog-test] testing idle/light-sleep deadline at $(TIMEOUT-S)s"
  watchdog.watchdog-start --timeout=(Duration --s=TIMEOUT-S)
  5.repeat:
    sleep --ms=1000
    watchdog.watchdog-feed
    print "[watchdog-test] sleep feed, alive at $(it + 1)s"

  bucket[STATE-KEY] = #[1]
  print "[watchdog-test] sleeping without feed; expect a reset within $(TIMEOUT-S)s"
  wait-bound

  watchdog.watchdog-stop
  bucket[STATE-KEY] = #[0x81]
  bucket.close
  print "[watchdog-test] idle deadline did not fire"

busy-wait --ms/int -> none:
  deadline := Time.monotonic-us + ms * 1000
  while Time.monotonic-us < deadline:
    null  // Spin.

wait-bound --busy/bool=false -> none:
  (4 * TIMEOUT-S).repeat:
    if busy:
      busy-wait --ms=1000
    else:
      sleep --ms=1000
    print "[watchdog-test] no feed for $(it + 1)s ..."
