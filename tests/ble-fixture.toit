// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.hci
import ble.experimental.advertising
import ble.experimental.scanning
import ble.experimental.connection
import ble.experimental.central
import ble.experimental.acl
import ble.experimental.att
import ble.experimental.gatt
import ble.experimental.signaling
import ble.experimental.transport show Transport
import expect show *
import monitor
import system

// Shared fixture for the experimental BLE host tests: an in-memory fake
// controller transport and helpers that script HCI, ACL and ATT exchanges.

append-bytes prefix/ByteArray suffix/ByteArray -> ByteArray:
  result := ByteArray (prefix.size + suffix.size)
  result.replace 0 prefix
  result.replace prefix.size suffix
  return result

gatt-reply transport/FakeTransport request/ByteArray response/ByteArray:
  att-sent transport request
  transport.received.add (att-event response)

att-event bytes/ByteArray --channel/int=4 -> ByteArray:
  pdu := ByteArray (4 + bytes.size)
  pdu.replace 0 #[bytes.size, 0, channel, 0]
  pdu.replace 4 bytes
  return incoming-acl pdu --start

att-sent transport/FakeTransport expected/ByteArray --channel/int=4:
  packet := transport.sent.take
  expect-equals #[2, 0x34, 2, expected.size + 4, 0, expected.size, 0, channel, 0] packet[..9]
  expect-equals expected packet[9..]
  transport.received.add #[4, 0x13, 5, 1, 0x34, 2, 1, 0]

incoming-acl bytes/ByteArray --start/bool=false -> ByteArray:
  result := ByteArray (5 + bytes.size)
  result.replace 0 #[2, 0x34, start ? 0x22 : 0x12, bytes.size, 0]
  result.replace 5 bytes
  return result

connection-event ::= #[4, 0x3e, 19, 1, 0, 0x34, 2, 0, 1,
                       1, 2, 3, 4, 5, 6, 24, 0, 0, 0, 0x90, 1, 0]

create-command ::= #[1, 13, 32, 25, 16, 0, 16, 0, 0, 1,
                     1, 2, 3, 4, 5, 6, 0, 24, 0, 40, 0, 0, 0, 0x90, 1, 0, 0, 0, 0]

status-reply transport/FakeTransport expected/ByteArray:
  expect-equals expected transport.sent.take
  transport.received.add #[4, 15, 4, 0, 1, expected[1], expected[2]]

class FakeTransport implements Transport:
  received/hci.Packets ::= hci.Packets 16
  sent/hci.Packets ::= hci.Packets 16
  sent-count/int := 0
  closed/bool := false
  /**
  Features this fake controller reports for every LE Read Remote Features.

  The host reads remote features on each new central link. The fake answers
    such commands itself, without exposing them through $sent, so scripted
    responders only see the traffic they scripted. Set to null to script the
    exchange manually.
  */
  auto-features/ByteArray? := #[1, 0, 0, 0, 0, 0, 0, 0]
  feature-reads/int := 0
  /**
  Whether this fake completes disconnects itself.

  A link-local failure ends only that link, and the owner's cleanup then
    disconnects it. Tests about the failure, not the disconnect, opt in here:
    the command is answered with Command Status and Disconnection Complete
    (reason 0x16) without appearing in $sent or $sent-count.
  */
  auto-disconnect/bool := false
  disconnects/int := 0

  receive -> ByteArray: return received.take

  send packet/ByteArray -> none:
    if closed: throw "FAKE_CLOSED"
    if auto-features and packet.size == 6 and packet[0] == 1 and packet[1] == 0x16 and packet[2] == 0x20:
      feature-reads++
      received.add #[4, 0x0f, 4, 0, 1, 0x16, 0x20]
      received.add (#[4, 0x3e, 12, 4, 0, packet[4], packet[5]] + auto-features)
      return
    if auto-disconnect and packet.size == 7 and packet[0] == 1 and packet[1] == 0x06 and packet[2] == 0x04:
      disconnects++
      received.add #[4, 0x0f, 4, 0, 1, 0x06, 0x04]
      received.add #[4, 0x05, 4, 0, packet[4], packet[5], 0x16]
      return
    sent-count++
    sent.add packet.copy

  send-if packet/ByteArray [allowed] -> bool:
    if not allowed.call: return false
    send packet
    return true

  close -> none:
    closed = true
    received.fail "FAKE_CLOSED"
    sent.fail "FAKE_CLOSED"

reply transport/FakeTransport expected/ByteArray data/ByteArray:
  expect-equals expected transport.sent.take
  event := ByteArray (7 + data.size)
  event.replace 0 #[4, 14, 4 + data.size, 1, expected[1], expected[2], 0]
  event.replace 7 data
  transport.received.add event

class ThrowingCloseTransport extends FakeTransport:
  started/monitor.Latch ::= monitor.Latch
  ended/monitor.Latch ::= monitor.Latch
  closes/int := 0

  receive -> ByteArray:
    started.set true
    try:
      return super
    finally:
      critical-do --no-respect-deadline: ended.set true

  close -> none:
    closes++
    // Model a close failure that leaves receive waiting for input.
    throw "TRANSPORT_CLOSE_FAILED"

initialize-replies transport/FakeTransport --shared/bool=false --acl-length/int=251 --receive-flow/bool=false
    --extended/bool=false --data-length/bool=false --phy-2m/bool=false --privacy/bool=false:
  reply transport #[1, 3, 12, 0] #[]
  reply transport #[1, 1, 16, 0] #[10, 1, 0, 10, 93, 0, 1, 0]
  commands := ByteArray 64
  if receive-flow: commands[10] = 0xe0
  if extended:
    commands[36] = 0x3e
    commands[37] = 0x81
  if data-length: commands[33] = 0x40
  if phy-2m: commands[35] = 0x60
  if privacy:
    commands[34] |= 0x68
    commands[35] |= 0x06
    commands[39] |= 0x04
  reply transport #[1, 2, 16, 0] commands
  reply transport #[1, 3, 16, 0] #[0, 0, 0, 0, 0x40, 0, 0, 0]
  reply transport #[1, 9, 16, 0] #[1, 2, 3, 4, 5, 6]
  reply transport #[1, 3, 32, 0] #[(data-length ? 0x21 : 1) | (privacy ? 0x40 : 0), (extended ? 0x10 : 0) | (phy-2m ? 1 : 0), 0, 0, 0, 0, 0, 0]
  if shared:
    reply transport #[1, 2, 32, 0] #[0, 0, 0]
    reply transport #[1, 5, 16, 0] #[0xfb, 0, 0, 8, 0, 0, 0]
  else:
    reply transport #[1, 2, 32, 0] #[acl-length & 0xff, acl-length >> 8, 8]
  reply transport #[1, 1, 12, 8, 0x90, 0x80, 4, 0, 0, 0x80, 0, 0x20] #[]
  reply transport #[1, 1, 32, 8, 0x5f, 0x08, 0, 0, 0, 0, 0, 0] #[]
  if data-length: reply transport #[1, 0x24, 32, 4, 0xfb, 0, 0x48, 8] #[]
  if phy-2m: reply transport #[1, 0x31, 32, 3, 0, 3, 3] #[]

/** Waits until $link has ended, whatever error ended it. */
wait-ended link/central.Link -> none:
  catch --unwind=(: it == DEADLINE-EXCEEDED-ERROR or it == CANCELED-ERROR):
    link.wait-disconnected
