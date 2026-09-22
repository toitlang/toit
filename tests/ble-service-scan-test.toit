// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.transport
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import ble.experimental.service.scanning-provider as scanning-provider
import ble.experimental.service.provider as rpc
import .ble-fixture as fixture

main:
  with-timeout --ms=10_000:
    report-properties
    decoded-advertisement
    scan-only-capabilities
    ["stop", "timeout", "throw", "cancel", "overflow", "filter", "limited", "stop-rejected"].do: | mode/string | run mode
    ["stop", "throw", "cancel", "idle-cancel", "stop-rejected"].do: | mode/string | run mode --unbounded
    run "stop" --private
    run "throw" --private
    run "cancel" --private --unbounded

run mode/string --unbounded/bool=false --private/bool=false:
  provider := Provider --private=private
  provider.install
  first := clients.Client
  second := clients.Client
  first.open
  second.open
  capabilities := first.capabilities
  expect (capabilities.scanning and capabilities.gatt-peripheral)
  expect capabilities.continuous-scanning
  expect-equals 512 capabilities.max-value-size
  expect-equals 517 capabilities.max-mtu
  expect-equals 60_000_000 capabilities.max-scan-duration.in-us
  expect-equals 1 capabilities.max-sessions
  entered := monitor.Latch
  result := monitor.Latch
  worker/Task? := null
  responder := task::
    fixture.initialize-replies provider.radio
    if private: fixture.reply provider.radio #[1, 5, 32, 6, 0xaa, 0xfb, 0x0d, 0x94, 0x81, 0x70] #[]
    fixture.reply provider.radio #[1, 11, 32, 7, private ? 1 : 0, 16, 0, 16, 0, private ? 1 : 0, 0] #[]
    fixture.reply provider.radio #[1, 12, 32, 2, 1, 1] #[]
    provider.radio.received.add #[4, 0x3e, 12, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 0, 127]
    if mode == "limited":
      // General discovery, no flags, and scan response must not escape.
      provider.radio.received.add #[4, 0x3e, 15, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 3, 2, 1, 6, 127]
      provider.radio.received.add #[4, 0x3e, 12, 2, 1, 4, 0, 1, 2, 3, 4, 5, 6, 0, 127]
      provider.radio.received.add #[4, 0x3e, 15, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 3, 2, 1, 5, 127]
    if mode == "filter":
      provider.radio.received.add #[4, 0x3e, 16, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 4, 3, 3, 0xf0, 0xff, 127]
    if mode == "overflow":
      entered.get
      payload := #[0, 0, 1, 2, 3, 4, 5, 6, 0, 127]
      // Fifty reports in two HCI events: the HCI queue cannot overflow, while
      // the blocked client's 32-report queue must drop exactly eighteen.
      2.repeat: provider.radio.received.add (#[4, 0x3e, 252, 2, 25] + (ByteArray 250: payload[it % 10]))
    if mode == "stop-rejected":
      expect-equals #[1, 12, 32, 2, 0, 0] provider.radio.sent.take
      provider.radio.received.add #[4, 14, 4, 1, 12, 32, 12]
    else:
      fixture.reply provider.radio #[1, 12, 32, 2, 0, 0] #[]
  try:
    expect-throw "INVALID_ARGUMENT": first.scan --duration=(Duration --us=0): unreachable
    expect-throw "INVALID_ARGUMENT": first.scan --duration=(Duration --us=-1): unreachable
    expect-throw "INVALID_ARGUMENT": first.scan --duration=(Duration --us=60_000_001): unreachable
    worker = task::
      stats := null
      error := catch:
        stats = first.scan --active=private --limited-only=(mode == "limited") --continuous=unbounded --duration=(Duration --ms=100) --service-uuid=(mode == "filter" ? #[0xf0, 0xff] : null): | report/clients.ScanReport |
          expect-equals #[1, 2, 3, 4, 5, 6] report.address
          expect-null report.rssi
          expect-equals (mode == "filter" ? #[3, 3, 0xf0, 0xff] : (mode == "limited" ? #[2, 1, 5] : #[])) report.data
          system.process-stats --gc
          expect-equals #[1, 2, 3, 4, 5, 6] report.address
          expect-throw "GATT_SERVICE_BUSY": second.configure
          // Describing support neither reserves nor steals an active adapter.
          expect second.capabilities.scanning
          entered.set true
          if mode == "throw": throw "SCAN_CALLBACK_FAILED"
          if mode == "cancel": (monitor.Latch).get
          if mode == "overflow":
            while not provider.radio.closed: sleep --ms=1
          mode == "timeout" or mode == "idle-cancel"
      result.set [error, stats]
    entered.get
    expect-equals (unbounded ? null : 100_000) provider.last-duration
    if mode == "idle-cancel":
      // Let the callback return and the next report request block.
      sleep --ms=20
    if mode == "cancel" or mode == "idle-cancel": worker.cancel
    if mode != "cancel" and mode != "idle-cancel":
      values := result.get
      if mode == "throw":
        expect-equals "SCAN_CALLBACK_FAILED" values[0]
      else if mode == "stop-rejected":
        expect (values[0] is string)
        expect (values[0].contains "status=12")
      else:
        expect-null values[0]
        expect-equals (mode == "overflow" ? [0, 18, 32] : [0, 0, 0]) values[1]
    while not provider.last.is-released: sleep --ms=1
    expect provider.radio.closed
    expect-equals 1 provider.address-calls
    next := second.configure
    next.close
  finally:
    if worker: worker.cancel
    first.close
    second.close
    responder.cancel
    provider.uninstall

class Provider extends providers.Provider:
  radio/fixture.FakeTransport ::= fixture.FakeTransport
  last/rpc.Session? := null
  last-duration/int? := null
  private_/bool
  address-calls/int := 0

  constructor --private/bool=false:
    private_ = private
    super
  scan-local-random-address -> ByteArray?:
    address-calls++
    return private_ ? #[0xaa, 0xfb, 0x0d, 0x94, 0x81, 0x70] : null
  open-transport -> transport.Transport: return radio
  create-scan client/int arguments/List -> rpc.Session:
    last-duration = arguments[0]
    last = super client arguments
    return last

scan-only-capabilities:
  provider := ScanOnlyProvider
  provider.install
  client := clients.Client
  client.open
  try:
    capabilities := client.capabilities
    expect capabilities.scanning
    expect capabilities.continuous-scanning
    expect (not capabilities.gatt-peripheral)
    expect-equals 0 capabilities.max-value-size
    expect-equals 0 capabilities.max-mtu
    expect-equals 60_000_000 capabilities.max-scan-duration.in-us
    expect-equals 1 capabilities.max-sessions
    expect-throw "GATT_UNSUPPORTED_SERVICE_OPERATION": client.configure
    expect-throw "GATT_UNSUPPORTED_SERVICE_OPERATION": client.session
    expect client.capabilities.scanning
    expect-equals 0 provider.transport-opens
  finally:
    client.close
    provider.uninstall

class ScanOnlyProvider extends scanning-provider.Provider:
  transport-opens/int := 0

  constructor:
    super

  open-transport -> transport.Transport:
    transport-opens++
    throw "UNEXPECTED_CONTROLLER_OPEN"

decoded-advertisement:
  raw := #[2, 1, 6, 4, 9, 84, 111, 105, 3, 3, 0x0f, 0x18]
  report := clients.ScanReport [0, 0, #[1, 2, 3, 4, 5, 6], raw.copy, null]
  decoded := report.advertisement
  expect-equals "Toi" decoded.name
  expect-equals raw decoded.to-raw
  report.data.fill 0
  system.process-stats --gc
  expect-equals raw decoded.to-raw
  report.data.replace 0 raw
  decoded.data-blocks[0].data.fill 0
  expect-equals raw report.data
  expect-equals raw report.advertisement.to-raw
  // Invalid framing remains inspectable without aliasing the retained report.
  // This includes zero-length terminators and incomplete length/type fields.
  32.repeat: | size/int |
    [0, 1, 31, 255].do: | length/int |
      bytes := ByteArray size --initial=length
      report = clients.ScanReport [4, 0, #[1, 2, 3, 4, 5, 6], bytes.copy, null]
      parsed := report.advertisement
      expect-equals bytes parsed.to-raw
      report.data.fill 99
      system.process-stats --gc
      expect-equals bytes parsed.to-raw

report-properties:
  // Core 6.3, Vol 4 Part E, 7.7.65.2: ADV_IND, ADV_DIRECT_IND,
  // ADV_SCAN_IND, ADV_NONCONN_IND, SCAN_RSP, then reserved event types.
  expected := [
    [true, true, false],
    [true, false, false],
    [false, true, false],
    [false, false, false],
    [null, null, true],
  ]
  256.repeat: | type/int |
    report := clients.ScanReport [type, 0, #[1, 2, 3, 4, 5, 6], #[], null]
    properties := [report.connectable, report.scannable, report.scan-response]
    expect-equals (type < expected.size ? expected[type] : [null, null, null]) properties
    expect-equals type report.event-type
