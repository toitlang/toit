// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the sandbox heap floor: the heap of a sandboxed container doesn't grow
  into the memory that must stay free for the system process and the
  trusted containers (on a device, the install-time verifier runs in the
  system process and needs it).

On the host the floor works on a simulated system heap (-Xsandbox_system_heap,
  each sandboxed process alone in it): with a 600 KB system heap and a 400
  KB floor, a sandboxed container can't take more than 200 KB, although its
  heap quota is 2 MB, neither in heap pages nor in external byte arrays. A
  trusted container with the same quota is not limited, and without the
  floor the sandboxed container gets its quota.

Before the floor, a sandboxed container on a device could grow until the
  system had less than 1 KB free (memory-pressure soak, an untrusted
  install's verification ran out of memory).
*/

import expect show *
import host.file
import .sandbox-util show *

PROGRAM ::= """
import system.containers

main args:
  if args is Map:
    grow args["external"]
    return
  [true, false].do: | untrusted |
    [false, true].do: | external |
      container := containers.start containers.current {"external": external}
          --untrusted=untrusted
          --quotas={"heap": 2_000_000}
      container.wait

grow external/bool -> none:
  if external:
    // External (malloced) byte arrays: charged to the heap.
    exception := catch: ByteArray 300_000
    print "external: \$(exception or "ok")"
    return
  // Heap pages: 1 KB byte arrays, kept alive.
  list := []
  exception := catch:
    1_000.repeat: list.add (ByteArray 1_000)
  size := list.size
  list = []  // Frees the memory (printing allocates).
  print "grown: \$size"
"""

main args:
  toit-run := args[0]
  with-tmp-directory: | dir |
    source := "$dir/heap-floor-main.toit"
    write-file source PROGRAM
    floor := run toit-run source ["-Xsandbox_heap_floor=400000", "-Xsandbox_system_heap=600000"]
    // Sandboxed: [heap pages, external]; then trusted.
    expect floor[0] < 200
    expect floor[0] > 20
    expect (floor[1] == "OUT_OF_MEMORY" or floor[1] == "ALLOCATION_FAILED")
    expect-equals 1000 floor[2]
    expect-equals "ok" floor[3]
    none := run toit-run source []
    expect-equals 1000 none[0]
    expect-equals "ok" none[1]
    expect-equals 1000 none[2]
    expect-equals "ok" none[3]

/** Runs the program and returns its four results. */
run toit-run/string source/string flags/List -> List:
  result := run-process [toit-run] + flags + [source] --timeout-ms=60_000
  print result.output
  expect-equals 0 result.exit-code
  results := []
  result.output.split "\n": | line/string |
    if line.starts-with "grown: ": results.add (int.parse line[7..])
    if line.starts-with "external: ": results.add line[10..]
  expect-equals 4 results.size
  return results
