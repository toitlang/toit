// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.acl
import ble.experimental.central
import ble.experimental.connection
import ble.experimental.encryption
import ble.experimental.extended-central as extended
import ble.experimental.hci
import expect show *
import io
import monitor
import system
import .ble-fixture as fixture
import .ble-connect-isolation-test as isolation
import .ble-multilink-test as links
import .ble-receive-flow-fixture as flow

ERRORS ::= {
  "HCI_MALFORMED_PACKET",
  "HCI_UNSUPPORTED_PACKET_TYPE",
  "HCI_MALFORMED_CONNECTION_EVENT",
  "HCI_UNEXPECTED_CONNECTION_ROLE",
  "HCI_UNEXPECTED_CONTROLLER_PRIVACY",
  "HCI_MALFORMED_ENCRYPTION_EVENT",
  "HCI_MALFORMED_ACL_CREDITS",
}

// Checked-in seeds make every truncation and byte substitution reproducible.
seeds -> List:
  return [
    fixture.connection-event.copy,
    isolation.completed-connection 1 0x234,
    #[4, 5, 4, 0, 0x34, 2, 0x13],
    #[4, 0x3e, 10, 3, 0, 0x34, 2, 24, 0, 0, 0, 0x90, 1],
    #[4, 8, 4, 0, 0x34, 2, 1],
    #[4, 0x59, 5, 0, 0x34, 2, 1, 16],
    #[4, 0x30, 3, 0, 0x34, 2],
    #[4, 0x3e, 13, 5, 0x34, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    #[4, 0x13, 9, 2, 0x34, 2, 1, 0, 0x35, 2, 1, 0],
  ]

main:
  with-timeout --ms=30_000:
    seeds.do: | seed/ByteArray |
      check seed
      seed.size.repeat: | length/int |
        truncated := seed[..length].copy
        check truncated
        if length >= 3:
          truncated[2] = length - 3
          check truncated
      check (seed + #[0])
      seed.size.repeat: | offset/int |
        256.repeat: | value/int |
          mutated := seed.copy
          mutated[offset] = value
          check mutated
      system.process-stats --gc
    // Broken connection frames must fail both live links and join the reader,
    // rather than merely raising an exception in a standalone parser.
    [false, true].do: | extended-mode/bool |
      completion := isolation.completed-connection 1 0x234 --extended-mode=extended-mode
      [completion, #[4, 5, 4, 0, 0x34, 2, 0x13]].do: | seed/ByteArray |
        seed.size.repeat: | length/int |
          packet := seed[..length].copy
          if length >= 3: packet[2] = length - 3
          shared-rejection packet --receive-flow=false --extended-mode=extended-mode
          shared-rejection packet --receive-flow --extended-mode=extended-mode
        [0x0f00, 0xf000, 0xffff].do: | handle/int |
          packet := seed.copy
          io.LITTLE-ENDIAN.put-uint16 packet (packet[1] == 5 ? 4 : 5) handle
          shared-rejection packet --receive-flow=false --extended-mode=extended-mode
          shared-rejection packet --receive-flow --extended-mode=extended-mode
    // Resolution is disabled. Reject unexpected local/peer RPA metadata even
    // after the receive ledger has registered the otherwise valid new handle.
    12.repeat: | offset/int |
      packet := isolation.completed-connection 3 0x236
      packet[15 + offset] = 1
      [false, true].do: | receive-flow/bool |
        shared-rejection packet --receive-flow=receive-flow --extended-mode
            --expected="HCI_UNEXPECTED_CONTROLLER_PRIVACY"

checked packet/ByteArray [decode]:
  original := packet.copy
  error := catch: decode.call
  if error: expect (ERRORS.contains error)
  expect-equals original packet

check packet/ByteArray:
  [0, 1].do: | role/int |
    checked packet:
      result := extended.decode-completion packet --role=role
      if result:
        if result.status == 0:
          expect (0 <= result.handle <= 0x0eff and result.address.size == 6)
          expect-equals role result.role
          expect (0 <= result.address-type <= 1)
          expect (6 <= result.interval <= 3200 and 0 <= result.latency <= 499)
          expect (10 <= result.supervision-timeout <= 3200)
          expect (result.supervision-timeout * 4 > (result.latency + 1) * result.interval)
        else:
          expect-equals 0 result.handle
          expect-equals #[] result.address
          expect-equals 0 result.interval
          expect-equals 0 result.latency
          expect-equals 0 result.supervision-timeout
  checked packet:
    result := connection.decode-completion packet
    if result:
      if result.status == 0:
        expect (0 <= result.handle <= 0x0eff and result.address.size == 6)
        expect-equals 0 result.role
      else:
        expect-equals 0 result.handle
        expect-equals #[] result.address
  checked packet:
    result := connection.decode-completion packet --role=1
    if result and result.status == 0: expect-equals 1 result.role
  checked packet:
    result := connection.decode-disconnection packet
    if result: expect (0 <= result.handle <= 0x0eff)
  checked packet:
    result := connection.decode-update packet
    if result:
      expect (0 <= result.handle <= 0x0eff)
      if result.status == 0:
        expect (result.supervision-timeout * 4 > (result.latency + 1) * result.interval)
      else:
        expect-equals 0 result.interval
        expect-equals 0 result.latency
        expect-equals 0 result.supervision-timeout
  checked packet:
    result := encryption.decode-change packet
    if result:
      expect (0 <= result.handle <= 0x0eff)
      if result.status != 0: expect (not result.enabled)
  checked packet:
    result := encryption.decode-key-request packet
    if result:
      expect (0 <= result.handle <= 0x0eff)
      expect-equals 8 result.random.size
  original := packet.copy
  callbacks := 0
  error := catch:
    acl.completed-do packet: | handle/int count/int |
      callbacks++
      expect (0 <= handle <= 0x0eff and 0 <= count <= 0xffff)
  if error:
    expect (ERRORS.contains error)
    // Complete structural validation must precede any credit side effects.
    expect-equals 0 callbacks
  expect-equals original packet

shared-rejection packet/ByteArray --receive-flow/bool --extended-mode/bool=false
    --expected/string?=null:
  transport := fixture.FakeTransport
  controller := hci.Controller transport
  host/central.Central? := null
  ready := monitor.Latch
  responder := task::
    if receive-flow: flow.initialize transport true
    // Wait until construction publishes the selected host before replying.
    while not host: yield
    isolation.establish transport host 1 0x234 --extended-mode=extended-mode
    isolation.establish transport host 2 0x235 --extended-mode=extended-mode
    ready.get
    transport.received.add packet
  try:
    if receive-flow: hci.initialize controller --receive-acl-packets=4
    host = extended-mode
        ? extended.Central controller --link-limit=2 --acl-count=2
        : central.Central controller --link-limit=2 --acl-count=2
    first := host.connect (links.address 1) --address-type=1
    second := host.connect (links.address 2) --address-type=1
    sent := transport.sent-count
    ready.set true
    failure := catch: first.receive
    if expected:
      expect-equals expected failure
    else if receive-flow and packet.size >= 3 and packet[1] == 5:
      expect-equals "HCI_RX_INVALID_DISCONNECTION" failure
    else if receive-flow and packet.size >= 4:
      expect-equals "HCI_RX_INVALID_CONNECTION" failure
    else:
      expect (ERRORS.contains failure)
    expect-throw failure: second.receive
    expect (not first.connected and not second.connected and transport.closed)
    host.wait-closed
    expect-equals sent transport.sent-count
  finally:
    responder.cancel
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
