// Smoke test for the internal AON (always-on) VM-liveness watchdog
// (CONFIG_TOIT_EC618_VM_WATCHDOG). It confirms the guard does NOT disturb a
// healthy device: the device boots without looping, survives normal (sleepy)
// operation past the ~27 s AON window, and survives a long in-program sleep
// (the AON is gated while the chip sleeps).
//
// This does NOT exercise the firing path. The AON fires when the scheduler
// stops cycling for ~27 s — a deadlock, a stuck C++ primitive, or a lone
// CPU-bound process that never yields (Toit does not preempt a process when no
// other process is ready). Firing means resetting the device, so it cannot be
// a passing automated test; it is verified manually with a build that has the
// scheduler feed disabled (then a busy loop resets at ~27 s).
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

  print "[aon-test] phase 2: single 40s in-program sleep (AON is gated while sleeping)"
  sleep --ms=40000

  print "[aon-test] SURVIVED — the AON guard does not disturb a healthy device"
  print "[aon-test] ALL GOOD"
