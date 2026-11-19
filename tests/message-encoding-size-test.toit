// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.tison
import expect show *

// The encoders write an object once per reference, so a small object graph
// can have an encoding of many gigabytes. The size of such an encoding was
// truncated to 32 bits, and the buffer allocated for the truncated size
// overflowed when the encoding was written.

process-send pid/int type/int message -> bool:
  #primitive.core.process-send

// Pids count up from zero and are never reused.
NO-SUCH-PID ::= 0x3fff_fff0

main:
  test-tison
  test-tison-wrap-around
  test-message

test-tison:
  big := "x" * 50_000_000
  // 5 GB of TISON from 50 MB of memory.
  expect-throw "OUT_OF_RANGE": tison.encode (List 100: big)
  // Smaller ones still work.
  small := tison.encode (List 3: "y" * 1000)
  expect-equals (List 3: "y" * 1000) (tison.decode small)

test-tison-wrap-around:
  // 100 * 100 * 43 references to a 10 KB string are 4.3 GB. On a 32-bit
  // VM the size wrapped around to a few megabytes.
  node/any := "w" * 10_000
  [43, 100, 100].do: | n |
    child := node
    node = List n: child
  expect-throw "OUT_OF_RANGE": tison.encode node

test-message:
  // Strings up to 128 bytes are copied into the message itself. 200^4
  // references to one are 200 GB. The encoder stops at 1 GB.
  node/any := "z" * 120
  4.repeat:
    child := node
    node = List 200: child
  start := Time.monotonic-us
  expect-throw "OUT_OF_RANGE": process-send NO-SUCH-PID 100 node
  elapsed := Time.monotonic-us - start
  print "gave up after $(elapsed / 1000) ms"
  expect-not (process-send NO-SUCH-PID 100 [1, 2, 3])
