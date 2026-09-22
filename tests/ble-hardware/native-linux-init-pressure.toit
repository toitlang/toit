// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.native
import host.directory
import system

// Requires CAP_NET_ADMIN. Opens management sockets but sends no commands.
main:
  slots := List 2048
  warm := native.NativeTransport.management
  warm.close
  system.process-stats --gc
  sleep --ms=10
  baseline := descriptors
  set-max-heap-size_ (256 * 1024)
  failures := 0
  opened := 0
  with-timeout --ms=60_000:
    16.repeat: | trial/int |
      filled := 0
      failure := catch:
        while filled < slots.size:
          slots[filled] = ByteArray 128 --initial=42
          filled++
      // Do not allocate a list while the ballast still exhausts the heap.
      if failure != "ALLOCATION_FAILED" and failure != "OUT_OF_MEMORY":
        throw "PRESSURE_NOT_REACHED"
      (trial + 1).repeat: slots[filled - 1 - it] = null
      radio/native.NativeTransport? := null
      error := catch: radio = native.NativeTransport.management
      slots.fill null
      system.process-stats --gc
      if radio:
        radio.close
        opened++
      else:
        if error != "ALLOCATION_FAILED" and error != "OUT_OF_MEMORY": throw error
        failures++
      with-timeout --ms=1_000:
        while descriptors != baseline: sleep --ms=1
      recovered := native.NativeTransport.management
      recovered.close
      with-timeout --ms=1_000:
        while descriptors != baseline: sleep --ms=1
      debug "LINUX_INIT_PRESSURE ROUND trial=$trial error=$error descriptors=$baseline"
    if failures == 0 or opened == 0: throw "INIT_PRESSURE_BOUNDARY_NOT_COVERED"
    debug "LINUX_INIT_PRESSURE COMPLETE failures=$failures opened=$opened descriptors=$baseline"

descriptors -> int:
  entries := directory.DirectoryStream "/proc/self/fd"
  count := 0
  while entries.next: count++
  return count
