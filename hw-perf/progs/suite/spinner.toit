// Copyright (C) 2026 Toit contributors.

// A CPU-bound container without blocking calls: the scheduler must preempt
// it (the core's back-branch preemption check) so that the suite's process
// keeps running.

main:
  sum := 0
  i := 0
  while i < 20_000_000:
    sum += i & 7
    i++
  print "SPINNER done $sum"
