// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import i2s
import .session
import ..paired.i2s as i2s-tests

main args/List:
  arg := args[0]
  expect (["philips16", "philips16-slave", "philips16-writer", "philips16-writer-slave",
      "msb32", "msb32-slave", "msb32-writer", "pcm16-writer", "pcm16-writer-slave"].contains arg)
  format := arg.starts-with "msb" ? i2s.Bus.FORMAT-MSB :
      (arg.starts-with "pcm" ? i2s.Bus.FORMAT-PCM-SHORT : i2s.Bus.FORMAT-PHILIPS)
  // Forward receive buffers to the tester faster than the audio stream.
  session := Session --baud-rate=921600
  try:
    i2s-tests.run session
        (IS-TESTEE ? 3 : 26)
        (IS-TESTEE ? 1 : 14)
        (IS-TESTEE ? 4 : 32)
        --testee-writer=(arg.contains "writer")
        --testee-master=(not (arg.contains "slave"))
        --bits=(arg.contains "32" ? 32 : 16)
        --format=format
    session.finish
  finally:
    session.close
