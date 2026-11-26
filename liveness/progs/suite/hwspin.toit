// Copyright (C) 2026 Toit contributors.

// Watchdog check: a 60 s busy loop without blocking calls in a spawned
// process while the main process ticks every second. Neither the task
// watchdog nor the dead-lock detection may fire; the ticks show how late
// the main process gets to run while the other one spins.

main:
  spawn::
    start := Time.monotonic-us
    sum := 0
    i := 0
    while Time.monotonic-us - start < 60_000_000:
      1000.repeat: sum += it & 7
      i++
    print "SPIN done outer=$i sum=$sum"
  ticks := 0
  max-late := 0
  62.repeat:
    before := Time.monotonic-us
    sleep --ms=1000
    late := Time.monotonic-us - before - 1_000_000
    if late > max-late: max-late = late
    ticks++
  print "SPIN ticks=$ticks max-late=$max-late us"
  // The only process busy for 30 s: the idle task must still get its turn.
  start := Time.monotonic-us
  i := 0
  while Time.monotonic-us - start < 30_000_000: i++
  print "SPIN main-busy done $i"
  print "SUITE done"
