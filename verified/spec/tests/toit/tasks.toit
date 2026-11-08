// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import monitor

monitor Counter:
  value_ := 0
  increment: value_++
  value: return value_
  wait-for n: await: value_ >= n

main:
  log := []
  counter := Counter
  3.repeat: | id |
    task::
      5.repeat:
        log.add "task $id step $it"
        counter.increment
        yield
  counter.wait-for 15
  print "counter: $counter.value"
  print log.size
  // Order of interleaving is deterministic with cooperative scheduling.
  log.do: print it

  // Channels between tasks.
  channel := monitor.Channel 2
  done := monitor.Latch
  task::
    sum := 0
    while true:
      v := channel.receive
      if v == null: break
      sum += v
    done.set sum
  for i := 1; i <= 10; i++: channel.send i
  channel.send null
  print "sum: $done.get"

  // Semaphore and mutex.
  mutex := monitor.Mutex
  shared := []
  tasks := []
  2.repeat: | id |
    tasks.add (task::
      3.repeat:
        mutex.do:
          shared.add "$(id)-$(it)"
          yield
          shared.add "$(id)-$(it)-end")
  semaphore := monitor.Semaphore
  task::
    while shared.size < 12: yield
    semaphore.up
  semaphore.down
  print shared

  // Task.group.
  results := Task.group [
    :: 1 + 1,
    :: "two",
    :: [3],
  ]
  print results
