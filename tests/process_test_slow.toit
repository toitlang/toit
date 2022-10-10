// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system.services
import monitor

main:
  test_simple
  test_priorities

test_simple:
  spawn:: expect_equals Process.PRIORITY_NORMAL Process.current.priority
  spawn --priority=100:: expect_equals 100 Process.current.priority
  spawn --priority=255:: expect_equals 255 Process.current.priority

test_priorities:
  [0, 1, 4, 8, 16, 32].do: | n/int |
    test_priority n --low=Process.PRIORITY_IDLE   --high=Process.PRIORITY_LOW

    test_priority n --low=Process.PRIORITY_IDLE   --high=Process.PRIORITY_NORMAL
    test_priority n --low=Process.PRIORITY_LOW    --high=Process.PRIORITY_NORMAL

    test_priority n --low=Process.PRIORITY_IDLE   --high=Process.PRIORITY_HIGH
    test_priority n --low=Process.PRIORITY_LOW    --high=Process.PRIORITY_HIGH
    test_priority n --low=Process.PRIORITY_NORMAL --high=Process.PRIORITY_HIGH

    test_priority n --low=Process.PRIORITY_IDLE   --high=Process.PRIORITY_CRITICAL
    test_priority n --low=Process.PRIORITY_LOW    --high=Process.PRIORITY_CRITICAL
    test_priority n --low=Process.PRIORITY_NORMAL --high=Process.PRIORITY_CRITICAL
    test_priority n --low=Process.PRIORITY_HIGH   --high=Process.PRIORITY_CRITICAL


test_priority n/int --low/int --high/int:
  Process.current.priority = Process.PRIORITY_CRITICAL
  print "$n x [$low < $high]"
  service := RegistrationServiceDefinition
  service.install

  baseline := calibrate service

  priorities := List n: low
  priorities.add high
  pids := List priorities.size

  counts := service.wait priorities.size:
    begin := Time.monotonic_us + 100_000
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
      expect (count * 1.4 >= baseline) --message="high priority too low"
    else:
      expect (count <= baseline * 1.2) --message="low priority too high"

  Process.current.priority = Process.PRIORITY_NORMAL

calibrate service/RegistrationServiceDefinition -> int:
  begin := Time.monotonic_us + 100_000
  end := begin + 500_000
  counts := service.wait 1: process begin end
  return counts[Process.current.id]

process begin/int end/int -> none:
  client := RegistrationServiceClient
  try:
    who := Process.current.id
    // Busy wait until we're supposed to begin.
    while Time.monotonic_us < begin: null
    count := run who end
    // Report back.
    client.register who count
  finally:
    client.close

run who/int until/int -> int:
  count := 0
  while Time.monotonic_us < until:
    fib 15
    count++
  return count

fib n:
  if n <= 2: return n
  return (fib n - 1) + (fib n - 2)

// ------------------------------------------------------------------

interface RegistrationService:
  static UUID/string ::= "82bcb411-e479-485e-9a9e-81031a5137b2"
  static MAJOR/int   ::= 1
  static MINOR/int   ::= 0

  register who/int count/int -> none
  static REGISTER_INDEX ::= 0

// ------------------------------------------------------------------

class RegistrationServiceClient extends services.ServiceClient implements RegistrationService:
  constructor --open/bool=true:
    super --open=open

  open -> RegistrationServiceClient?:
    client := open_
        RegistrationService.UUID
        RegistrationService.MAJOR
        RegistrationService.MINOR
        --timeout=(Duration --s=1)  // Use higher than usual timeout.
    return client and this

  register who/int count/int -> none:
    invoke_ RegistrationService.REGISTER_INDEX [who, count]

// ------------------------------------------------------------------

class RegistrationServiceDefinition extends services.ServiceDefinition implements RegistrationService:
  counts_/Map? := null
  signal_/monitor.Signal ::= monitor.Signal

  constructor:
    super "log" --major=1 --minor=0
    provides RegistrationService.UUID RegistrationService.MAJOR RegistrationService.MINOR

  handle pid/int client/int index/int arguments/any -> any:
    if index == RegistrationService.REGISTER_INDEX:
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
