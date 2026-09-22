// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system
import system.services
import expect show *

main:
  run-all

run-all --heap-size/int=(256 * 1024) --slot-count/int=16384:
  cold --heap-size=heap-size --slot-count=slot-count
  [false, true].do: | separate-clients/bool |
    48.repeat: | slack/int |
      shrink separate-clients slack --slot-count=slot-count

cold --heap-size/int=(256 * 1024) --slot-count/int=16384:
  provider := services.ServiceProvider "pressure" --major=0 --minor=1
  resource := Resource provider
  slots := List slot-count
  set-max-heap-size_ heap-size
  filled := 0
  exhausted := catch:
    while filled < slots.size:
      slots[filled] = ByteArray 8 --initial=42
      filled++
  expect (exhausted == "OUT_OF_MEMORY" or exhausted == "ALLOCATION_FAILED")
  error := catch: resource.close
  slots.fill null
  system.process-stats --gc
  count := 0
  provider.resources-do: count++
  print "RESOURCE_CLOSE_PRESSURE error=$error closed=$(resource.is-closed) callbacks=$(resource.closed) registered=$count"
  if error:
    expect (error == "OUT_OF_MEMORY" or error == "ALLOCATION_FAILED")
    expect (not resource.is-closed)
    expect-equals 0 resource.closed
  resource.close
  resource.close
  expect resource.is-closed
  expect-equals 1 resource.closed
  count = 0
  provider.resources-do: count++
  expect-equals 0 count

// Exercise removal from both the client map and a client's resource map at
// their shrinking boundary, including allocation failure after deletion.
shrink separate-clients/bool slack/int --slot-count/int=16384:
  provider := services.ServiceProvider "shrink" --major=0 --minor=1
  resources := List 12: Resource provider --client=(separate-clients ? it + 1 : 1)
  4.repeat: (resources[it] as Resource).close
  target/Resource := resources[4]
  slots := List slot-count
  filled := 0
  exhausted := catch:
    while filled < slots.size:
      slots[filled] = ByteArray 8 --initial=42
      filled++
  if exhausted != "OUT_OF_MEMORY" and exhausted != "ALLOCATION_FAILED": throw "PRESSURE_NOT_REACHED"
  (min filled slack).repeat:
    filled--
    slots[filled] = null
  error := catch: target.close
  slots.fill null
  system.process-stats --gc
  count := 0
  provider.resources-do: count++
  if error:
    expect (error == "OUT_OF_MEMORY" or error == "ALLOCATION_FAILED")
    expect (not target.is-closed)
    expect-equals 0 target.closed
    expect-equals 8 count
  else:
    expect target.is-closed
    expect-equals 1 target.closed
    expect-equals 7 count
  resources.do: | resource/Resource |
    resource.close
    resource.close
    expect-equals 1 resource.closed
  count = 0
  provider.resources-do: count++
  expect-equals 0 count
  next := Resource provider
  next.close
  expect-equals 1 next.closed
  print "RESOURCE_CLOSE_SHRINK separate-clients=$separate-clients slack=$slack retried=$(error != null) callbacks=1 remaining=0"

class Resource extends services.ServiceResource:
  closed/int := 0
  constructor provider/services.ServiceProvider --client/int=1: super provider client
  on-closed -> none: closed++
