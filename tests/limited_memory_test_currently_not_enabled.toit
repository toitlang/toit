// Copyright (C) 2019 Toitware ApS. All rights reserved.

import host.file
import reader
import ..system.kernel.test_primitive

// Linux-specific test of doing a GC on malloc failure.

main:
  if not file.is_file "/proc/self/maps": return

  5.repeat:
    hatch_::
      x := "funkytown"
      9.repeat: x += x
      sleep --ms=200

  str := "0123456789"
  str += str // 20
  str += str // 40
  str += str // 80
  str += str // 160
  str += str // 320
  str += str // 640
  str += str // 1280

  // Allocate some on-heap memory that stays around (about 4 Mbytes).  The
  // limit after a GC is set to this size + 50%, and we need a reasonable limit
  // so that we can hit the malloc limit from the system before we hit the +50%
  // limit.
  array := []
  1000.repeat:
    array.add str + str  // Large on-heap string

  // Set the malloc-returns-null limit to the current size of memory + a little.
  set_memory_limit (total_memory + 30000)

  str += str // 2560
  400.repeat:
    external := str + str  // Create off-heap string.

// Adds up the current memory so that we can set the limit a little higher.
total_memory:
  maps := file.Stream.for_read "/proc/self/maps"
  reader := reader.BufferedReader maps
  sum := 0
  while line := reader.read_line:
    if line.contains "rw-p":
      dash := line.index_of "-"
      if dash != -1 and dash < 20:
        from := int.parse line[..dash] --radix=16
        to := int.parse line[dash+1..dash*2+1] --radix=16
        bytes := to - from
        sum += bytes
  maps.close
  return sum
