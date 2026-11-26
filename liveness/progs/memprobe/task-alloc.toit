// Copyright (C) 2026 Toit contributors.

// Bytes allocated in the object heap per task (esp32-final, memory
// question 1): a task that does nothing, one that runs the soak worker's
// task body, and the latch the worker joins them with; format 1 vs 2 on
// one host (TOIT_BYTECODE_FORMAT=1 / 2).

import monitor
import system

N ::= 300

allocated -> int:
  return (system.process-stats)[system.STATS-INDEX-BYTES-ALLOCATED-IN-OBJECT-HEAP]

measure name/string [block] -> none:
  20.repeat: block.call it
  before := allocated
  N.repeat: block.call it
  print "TASK $name $((allocated - before) / N) B"

main:
  measure "empty task": | i |
    done := false
    task:: done = true
    while not done: yield
  measure "sum task": | i |
    done := false
    task::
      sum := 0
      (200 + i).repeat: sum += it
      done = true
    while not done: yield
  measure "sum+string task": | i |
    done := false
    task::
      sum := 0
      (200 + i).repeat: sum += it
      s := "$sum-$i"
      done = true
    while not done: yield
  measure "latch": | i |
    latch := monitor.Latch
    task:: latch.set i
    latch.get
