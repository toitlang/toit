// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system.services
import monitor

main:
  test-simple
  // TODO(kasper): The complex test is disabled for now. It is
  // hard to make non-flaky because it is inherently dependant
  // on timing.
  if false: test-priorities

test-simple:
  spawn:: expect-equals Process.PRIORITY-NORMAL Process.current.priority
  spawn --priority=100:: expect-equals 100 Process.current.priority
  spawn --priority=255:: expect-equals 255 Process.current.priority

test-priorities:
  [0, 1, 4, 8, 16, 32].do: | n/int |
    test-priority n --low=Process.PRIORITY-IDLE   --high=Process.PRIORITY-LOW

    test-priority n --low=Process.PRIORITY-IDLE   --high=Process.PRIORITY-NORMAL
    test-priority n --low=Process.PRIORITY-LOW    --high=Process.PRIORITY-NORMAL

    test-priority n --low=Process.PRIORITY-IDLE   --high=Process.PRIORITY-HIGH
    test-priority n --low=Process.PRIORITY-LOW    --high=Process.PRIORITY-HIGH
    test-priority n --low=Process.PRIORITY-NORMAL --high=Process.PRIORITY-HIGH

    test-priority n --low=Process.PRIORITY-IDLE   --high=Process.PRIORITY-CRITICAL
    test-priority n --low=Process.PRIORITY-LOW    --high=Process.PRIORITY-CRITICAL
    test-priority n --low=Process.PRIORITY-NORMAL --high=Process.PRIORITY-CRITICAL
    test-priority n --low=Process.PRIORITY-HIGH   --high=Process.PRIORITY-CRITICAL

test-priority n/int --low/int --high/int:
  Process.current.priority = Process.PRIORITY-CRITICAL
  print "$n x [$low < $high]"
  service := RegistrationServiceProvider
  service.install

  baseline := calibrate service

  priorities := List n: low
  priorities.add high
  pids := List priorities.size

  counts := service.wait priorities.size:
    begin := Time.monotonic-us + 100_000
    end := begin + 500_000
    priorities.size.repeat: | index/int |
      priority := priorities[index]
      process := spawn --priority=priority:: process begin end
      pids[index] = process.id
  service.uninstall --wait

  priorities.size.repeat: | index/int |
    priority := priorities[index]
    count := counts[pids[index]]
    if priority == high:
      expect (count * 1.5 >= baseline) --message="high priority too low"
    else:
      expect (count <= baseline * 1.2) --message="low priority too high"

  Process.current.priority = Process.PRIORITY-NORMAL

calibrate service/RegistrationServiceProvider -> int:
  begin := Time.monotonic-us + 100_000
  end := begin + 500_000
  counts := service.wait 1: process begin end
  return counts[Process.current.id]

process begin/int end/int -> none:
  client := RegistrationServiceClient
  try:
    who := Process.current.id
    // Busy wait until we're supposed to begin.
    while Time.monotonic-us < begin: null
    count := run who end
    // Report back.
    client.register who count
  finally:
    client.close

run who/int until/int -> int:
  count := 0
  while Time.monotonic-us < until:
    fib 15
    count++
  return count

fib n:
  if n <= 2: return n
  return (fib n - 1) + (fib n - 2)

// ------------------------------------------------------------------

interface RegistrationService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="82bcb411-e479-485e-9a9e-81031a5137b2"
      --major=1
      --minor=0

  register who/int count/int -> none
  static REGISTER-INDEX ::= 0

// ------------------------------------------------------------------

class RegistrationServiceClient extends services.ServiceClient implements RegistrationService:
  static SELECTOR ::= RegistrationService.SELECTOR
  constructor selector/services.ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  open -> RegistrationServiceClient?:
    return (super --timeout=(Duration --s=2)) and this  // Use higher than usual timeout.

  register who/int count/int -> none:
    invoke_ RegistrationService.REGISTER-INDEX [who, count]

// ------------------------------------------------------------------

class RegistrationServiceProvider extends services.ServiceProvider
    implements RegistrationService services.ServiceHandler:
  counts_/Map? := null
  signal_/monitor.Signal ::= monitor.Signal

  constructor:
    super "log" --major=1 --minor=0
    provides RegistrationService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == RegistrationService.REGISTER-INDEX:
      return register arguments[0] arguments[1]
    unreachable

  wait n/int [block] -> Map:
    counts := {:}
    try:
      counts_ = counts
      block.call
      signal_.wait: counts.size == n
      return counts
    finally:
      counts_ = null

  register who/int count/int -> none:
    counts_[who] = count
    signal_.raise
