// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.pipe
import system

// Closing a pipe while a write is still pending must not let the write's
// completion land in the freed pipe resource. On Windows the completion
// arrived when the reader went away, and wrote into whatever had reused the
// resource's memory. Here that is one of many freshly allocated external byte
// arrays of the same size.

// Bigger than the 8192-byte pipe buffer on Windows, so the write stays
// pending. Smaller than the pipe buffers elsewhere, so the write doesn't block.
PAYLOAD-SIZE ::= 12_000
// Covers the size of the Windows pipe resource.
SPRAY-SIZES ::= [104, 112, 120, 128, 136]
SPRAY-COUNT ::= 500
ITERATIONS ::= 5

// Marked as compiler test so we get the toit.run path.
main args:
  if args.size == 1 and args[0] == "CHILD":
    // Never read stdin; wait to be killed.
    sleep --ms=60_000
    return

  toit-run := args[0]
  ITERATIONS.repeat: test toit-run

test toit-run/string:
  process := pipe.fork
      --create-stdin
      toit-run
      [toit-run, system.program-path, "CHILD"]

  process.stdin.out.write (ByteArray PAYLOAD-SIZE)
  process.stdin.close

  spray := []
  SPRAY-SIZES.do: | size |
    SPRAY-COUNT.repeat: spray.add (ByteArray.external size)

  // The reader goes away, which completes a write that is still pending.
  process.kill --hard
  process.wait
  sleep --ms=50

  spray.do: | bytes/ByteArray |
    bytes.do: expect-equals 0 it
