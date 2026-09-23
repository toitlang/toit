// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Two centrals at once through the `ble` package on the Toit host: the
// provider allows two peripheral sessions on one shared controller, so the
// peripheral advertises again while its first central is connected, serves
// both, notifies both, and advertises again when one leaves.

import ble show *
import expect show *
import io
import monitor
import ble.experimental.signaling as signaling
import .ble-fixture as fixture
import .ble-multilink-test as multi
import .ble-peripheral-test as peripheral
import .ble-service-gatt-test as gatt

INPUT ::= 12
ECHO ::= 14
CCCD ::= 15

class TwoProvider extends gatt.TestProvider:
  constructor: super
  peripheral-session-limit -> int: return 2

main:
  with-timeout --ms=15_000:
    provider := TwoProvider
    provider.install
    written := monitor.Latch
    readvertised := monitor.Latch
    stopped := monitor.Latch
    finished := monitor.Latch
    done := monitor.Latch
    responder := task::
      catch --trace:
        radio := provider.radio
        fixture.initialize-replies radio
        peripheral.setup radio
        radio.received.add (connected 1 0x234)
        peripheral.reply radio 0x200a #[0]
        link-setup radio 0x234
        // The second session advertises while the first central is connected.
        peripheral.setup radio
        radio.received.add (connected 2 0x235)
        peripheral.reply radio 0x200a #[0]
        link-setup radio 0x235
        att-in radio 0x234 #[0x12, CCCD, 0, 1, 0]
        att-out radio 0x234 #[0x13]
        att-in radio 0x235 #[0x12, CCCD, 0, 1, 0]
        att-out radio 0x235 #[0x13]
        att-in radio 0x234 #[0x12, INPUT, 0, 1]
        att-out radio 0x234 #[0x13]
        att-in radio 0x235 #[0x12, INPUT, 0, 2]
        att-out radio 0x235 #[0x13]
        written.get
        att-out radio 0x234 #[0x1b, ECHO, 0, 42]
        att-out radio 0x235 #[0x1b, ECHO, 0, 42]
        // The first central leaves: a third session advertises for a replacement.
        multi.ended radio 0x234
        peripheral.setup radio
        readvertised.set true
        // stop-advertise ends that waiting session; the provider disables.
        stopped.get
        peripheral.reply radio 0x200a #[0]
        multi.ended radio 0x235
        finished.set true
    application := task::
      error := catch --trace: run written readvertised stopped finished
      done.set error
    try:
      expect-null done.get
    finally:
      responder.cancel
      application.cancel
      provider.uninstall

run written/monitor.Latch readvertised/monitor.Latch stopped/monitor.Latch finished/monitor.Latch -> none:
  adapter := Adapter
  peripheral := adapter.peripheral
  service := peripheral.add-service (BleUuid "fff0")
  input := service.add-write-only-characteristic (BleUuid "fff1") --requires-response
  echo := service.add-notification-characteristic (BleUuid "fff2")
  echo.set-value #[0x70, 0x17]
  peripheral.deploy
  peripheral.start-advertise
      --interval=(Duration --us=100_000)
      --allow-connections
      Advertisement --flags=(BLE-ADVERTISE-FLAGS-GENERAL-DISCOVERY | BLE-ADVERTISE-FLAGS-BREDR-UNSUPPORTED)
  values := {}
  values.add input.read
  values.add input.read
  expect-equals {#[1], #[2]} values
  echo.write #[42]
  written.set true
  readvertised.get
  peripheral.stop-advertise
  stopped.set true
  finished.get
  adapter.close

connected peer/int handle/int -> ByteArray:
  event := multi.connected peer handle
  event[7] = 1
  return event

link-setup radio/fixture.FakeTransport handle/int -> none:
  att-out radio handle (signaling.parameter-request 1) --channel=5
  att-in radio handle #[0x13, 1, 2, 0, 0, 0] --channel=5

att-in radio/fixture.FakeTransport handle/int bytes/ByteArray --channel/int=4 -> none:
  pdu := ByteArray (4 + bytes.size)
  pdu.replace 0 #[bytes.size, 0, channel, 0]
  pdu.replace 4 bytes
  multi.incoming radio handle pdu --start

att-out radio/fixture.FakeTransport handle/int expected/ByteArray --channel/int=4 -> none:
  packet := radio.sent.take
  header := ByteArray 9
  header[0] = 2
  io.LITTLE-ENDIAN.put-uint16 header 1 handle
  io.LITTLE-ENDIAN.put-uint16 header 3 (expected.size + 4)
  io.LITTLE-ENDIAN.put-uint16 header 5 expected.size
  io.LITTLE-ENDIAN.put-uint16 header 7 channel
  expect-equals header packet[..9]
  expect-equals expected packet[9..]
  multi.completed radio handle
