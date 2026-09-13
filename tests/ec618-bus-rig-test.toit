// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io

import .hw.ec618.framed-control show encode-frame
import .hw.ec618.run-bus-rig as rig

main:
  // Boot noise and a reply split across a PING retry must not lose bytes.
  pings := io.Buffer
  rig.wait-for-target (BootReader) pings
  expect-equals "PING\nPING\n" pings.bytes.to-string

  commands := encode-frame "PING"
  corrupt := encode-frame "must not reach the target"
  corrupt[3] ^= 1
  commands += corrupt + (encode-frame "QUIT") + (encode-frame "after quit")
  replies := io.Reader (#[0xff, '\n'] + "log\r\nBUS-REPLY READY\r\nBUS-REPLY OK\n".to-byte-array)
  bridge-out := io.Buffer
  target-out := io.Buffer
  rig.relay (io.Reader commands) bridge-out replies target-out
  expect-equals "PING\nQUIT\n" target-out.bytes.to-string
  expect-equals ((encode-frame "READY") + (encode-frame "OK")) bridge-out.bytes

  // Neither EOF nor a partial console reply may become a successful verdict.
  bridge-out = io.Buffer
  expect-throw "target console disconnected":
    rig.relay (io.Reader (encode-frame "QUIT")) bridge-out
        io.Reader "BUS-REPLY OK".to-byte-array
        io.Buffer
  expect bridge-out.bytes.is-empty
  expect-throw "control bridge disconnected":
    rig.relay (io.Reader #[]) bridge-out (io.Reader #[]) (io.Buffer)
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=20:
      rig.read-reply (SilentReader)
  print "bus-rig: PASS"

class BootReader extends io.Reader:
  step_ := 0

  read_ -> ByteArray?:
    step := step_++
    if step == 0: return "boot log\nBUS-RE".to-byte-array
    if step == 1: sleep --ms=2_000
    if step == 2: return "PLY READY\n".to-byte-array
    return null

class SilentReader extends io.Reader:
  read_ -> ByteArray?:
    sleep --ms=60_000
    return null
