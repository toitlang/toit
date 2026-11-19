// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import crypto.sha256 show sha256
import encoding.hex
import io
import .hw.esp-tester.mini-jag as agent

main:
  expect-equals #[1, 2, 3] (agent.read-container-chunk (io.Reader #[0, 0, 0, 3, 1, 2, 3]) 3)
  maximum := ByteArray 4096: it & 0xff
  expect-equals maximum (agent.read-container-chunk (io.Reader (#[0, 0, 16, 0] + maximum)) 4096)
  // Reject malformed lengths before consuming any payload as an allocation.
  expect-throw "invalid container chunk length: 0":
    agent.read-container-chunk (io.Reader #[0, 0, 0, 0]) 4096
  expect-throw "invalid container chunk length: 4097":
    agent.read-container-chunk (io.Reader #[0, 0, 16, 1]) 8192
  expect-throw "invalid container chunk length: 4294967295":
    agent.read-container-chunk (io.Reader #[255, 255, 255, 255]) 8192
  expect-throw "container chunk exceeds remaining image":
    agent.read-container-chunk (io.Reader #[0, 0, 0, 4]) 3

  // An interrupted exact read retains buffered payload. Reproduce that with
  // bytes which would otherwise be parsed as PING, UPGRADE, and ROLLBACK.
  reader := PartialReader
  progress := agent.ContainerUploadProgress
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=20:
      agent.read-container-chunk reader 16 --progress=progress
  expect-equals "chunk-payload" progress.stage
  expect-equals 16 progress.chunk-length
  // The upload diagnostic must inspect this count before recovery discards
  // the buffered payload; it distinguishes a short chunk from a missing one.
  expect-equals 3 reader.buffered-size
  // The checksum consumes only the retained bytes and must not wait for
  // the rest of the declared payload or additional input.
  with-timeout --ms=20:
    expect-equals (hex.encode (sha256 #['P', 'U', 'Z']))
        agent.buffered-upload-checksum reader
  expect-equals 0 reader.buffered-size
  reader.draining = true
  agent.discard-firmware-input reader
  expect-equals null reader.read
  // A new request sent after the error acknowledgement remains readable.
  reader.next = #[0, 0, 0, 2, 7, 9]
  expect-equals #[7, 9] (agent.read-container-chunk reader 2)
  // Reuse the progress object to ensure a truncated next header cannot report
  // the preceding chunk's payload length or stage.
  header := PartialReader
  header.next = #[0, 0]
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=20:
      agent.read-container-chunk header 16 --progress=progress
  expect-equals "chunk-header" progress.stage
  expect-equals 0 progress.chunk-length
  expect-equals 2 header.buffered-size
  print "EC618 container upload bounds and partial-payload recovery PASS"

class PartialReader extends io.Reader:
  next/ByteArray? := #[0, 0, 0, 16, 'P', 'U', 'Z']
  draining/bool := false

  read_ -> ByteArray?:
    if next:
      result := next
      next = null
      return result
    if not draining: sleep --ms=60_000
    return null
