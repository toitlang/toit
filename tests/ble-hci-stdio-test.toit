// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import io
import expect show *
import .ble-hardware.hci-stdio as bridge

main:
  expect-equals 120 (bridge.timeout-seconds ["3"])
  expect-equals 1 (bridge.timeout-seconds ["3", "1"])
  expect-equals 7_200 (bridge.timeout-seconds ["3", "7200"])
  ["0", "-1", "7201"].do: | seconds/string |
    expect-throw "INVALID_ARGUMENT": bridge.timeout-seconds ["3", seconds]
  [[], ["3", "120", "extra"]].do: | arguments/List |
    expect-throw "Usage: hci-stdio ADAPTER [SECONDS]": bridge.timeout-seconds arguments
  command := #[1, 3, 12, 0]
  acl := #[2, 1, 32, 1, 0, 7]
  combined := command + acl + command
  (combined.size + 1).repeat: | split/int |
    reader := Chunks [combined[..split], combined[split..]]
    expect-equals command (bridge.read-packet reader)
    expect-equals acl (bridge.read-packet reader)
    expect-equals command (bridge.read-packet reader)
    expect-null (bridge.read-packet reader)
  [command, acl].do: | packet/ByteArray |
    (packet.size - 1).repeat: | offset/int |
      expect-throw "UNEXPECTED_END_OF_READER":
        bridge.read-packet (io.Reader packet[..offset + 1])
  [0, 3, 4, 5, 255].do: | kind/int |
    expect-throw "HCI_BRIDGE_PACKET_TYPE": bridge.read-packet (io.Reader #[kind])
  // An oversized declaration must fail before trying to read an absent body.
  expect-throw "HCI_BRIDGE_PACKET_TOO_LARGE":
    bridge.read-packet (io.Reader #[2, 1, 32, 0xfc, 7])
  largest := #[2, 1, 32, 0xfb, 7] + (ByteArray 2043 --initial=7)
  expect-equals largest (bridge.read-packet (io.Reader largest))
  print "HCI_STDIO_FRAMING PASS"

class Chunks extends io.Reader:
  chunks_/List
  constructor .chunks_: super
  read_ -> ByteArray?:
    return chunks_.is-empty ? null : (chunks_.remove --at=0)
