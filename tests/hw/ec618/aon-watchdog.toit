// Smoke test for the platform AON (always-on) watchdog
// (CONFIG_TOIT_EC618_VM_WATCHDOG). It confirms the guard does not disturb a
// healthy device during normal operation or a long in-program sleep.
//
// This does not exercise the firing path. The vendor idle task and VM
// scheduler feed the AON independently of application watchdog feeds.
// watchdog-stop-ec618.toit separately checks 40 seconds of CPU-bound work
// that prevents idle from running, requiring scheduler feeding to survive.
//
// Use with:
//   toit tool firmware -e <envelope> container install --trigger=boot \
//       aon-watchdog aon-watchdog.snapshot

import ec618

main:
  print "[aon-test] reset reason: $(ec618.reset-reason-name ec618.reset-reason)"

  print "[aon-test] phase 1: 30s of normal (sleepy) operation past the ~27s AON window"
  30.repeat:
    sleep --ms=1000
    print "[aon-test] alive $(it + 1)s"

  print "[aon-test] phase 2: single 40s in-program sleep"
  sleep --ms=40000

  print "[aon-test] SURVIVED — the AON guard does not disturb a healthy device"
  print "[aon-test] ALL GOOD"
