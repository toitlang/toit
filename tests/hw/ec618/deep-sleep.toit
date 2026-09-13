// Tests deep sleep on EC618.
// The device should print the message, sleep 5 seconds, then reboot.
// On the boot AFTER the sleep, the mini-jag banner (and this test, if
// re-run) must report wake=rtc — the AP reset reason still reads
// power-on after a hibernate wake, so the wakeup cause is the only
// signal that distinguishes the timer wake from a cold boot.

import ec618

main:
  print "reset=$(ec618.reset-reason-name ec618.reset-reason) wake=$(ec618.wakeup-cause-name ec618.wakeup-cause)"
  print "Going to deep sleep for 5 seconds..."
  ec618.deep-sleep (Duration --s=5)
  // Should not reach here.
  print "ERROR: deep-sleep returned!"
