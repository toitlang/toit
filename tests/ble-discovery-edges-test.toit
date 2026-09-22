// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.gatt
import ble.experimental.hci
import expect show *
import io
import .ble-hci-test as fixture

main:
  with-timeout --ms=15_000:
    expanded-uuids
    upper-handles
    ambiguous-monitor
    malformed-pages
    foreign-records
    result-limit

with-peer script/List [body]:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  client/att.Client? := null
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    script.do: | pair/List | fixture.gatt-reply transport pair[0] pair[1]
  try:
    client = att.Client host (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1)
    return body.call client
  finally:
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed

expanded short/int -> ByteArray:
  bytes := #[0xfb, 0x34, 0x9b, 0x5f, 0x80, 0, 0, 0x80, 0, 0x10, 0, 0, 0, 0, 0, 0]
  io.LITTLE-ENDIAN.put-uint32 bytes 12 short
  return bytes

upper-handles:
  // Gaps are valid even between a declaration and its value (Vol 3 Part G
  // 2.5.1). Discovery must terminate without wrapping past handle 0xffff.
  uuid := expanded 0x2a01
  with-peer [
    [#[0x10, 1, 0, 0xff, 0xff, 0, 0x28], #[0x11, 6, 0xf0, 0xff, 0xff, 0xff, 0, 0x18]],
    [#[8, 0xf0, 0xff, 0xff, 0xff, 3, 0x28], #[9, 7, 0xf1, 0xff, 2, 0xf4, 0xff, 0, 0x2a]],
    [#[8, 0xf2, 0xff, 0xff, 0xff, 3, 0x28], (#[9, 21, 0xf9, 0xff, 2, 0xff, 0xff] + uuid)],
    [#[8, 0xfa, 0xff, 0xff, 0xff, 3, 0x28], #[1, 8, 0xfa, 0xff, 0x0a]],
    [#[4, 0xf5, 0xff, 0xf8, 0xff], #[5, 1, 0xf7, 0xff, 1, 0x29]],
    [#[4, 0xf8, 0xff, 0xf8, 0xff], (#[5, 2, 0xf8, 0xff] + (expanded 0x2904))],
    [#[0x0a, 0xff, 0xff], #[0x0b, 42]],
  ]: | client/att.Client |
    services := gatt.services client
    expect-equals 1 services.size
    service/gatt.Service := services.first
    expect-equals 0xfff0 service.start
    expect-equals 0xffff service.end
    characteristics := gatt.characteristics client service
    expect-equals 2 characteristics.size
    first/gatt.Characteristic := characteristics.first
    last/gatt.Characteristic := characteristics.last
    expect-equals 0xfff4 first.handle
    expect-equals 0xfff8 first.end
    expect-equals 0xffff last.handle
    expect-equals 0xffff last.end
    expect-equals uuid last.uuid
    descriptors := gatt.descriptors client first
    expect-equals 2 descriptors.size
    expect-equals 0xfff7 (descriptors.first as gatt.Descriptor).handle
    expect-equals 0xfff8 (descriptors.last as gatt.Descriptor).handle
    expect-equals (expanded 0x2904) (descriptors.last as gatt.Descriptor).uuid
    expect-equals 0 (gatt.descriptors client last).size
    // Exact following traffic detects extra discovery requests without sleeps.
    expect-equals #[42] (gatt.read client last)
  with-peer [
    [#[4, 0xff, 0xff, 0xff, 0xff], #[5, 1, 0xff, 0xff, 1, 0x29]],
    [#[0x0a, 0xfe, 0xff], #[0x0b, 43]],
  ]: | client/att.Client |
    characteristic := gatt.Characteristic 0xfffc 0xfffe 2 #[0, 0x2a]
    characteristic.end = 0xffff
    descriptors := gatt.descriptors client characteristic
    expect-equals 1 descriptors.size
    expect-equals 0xffff (descriptors.first as gatt.Descriptor).handle
    expect-equals #[43] (gatt.read client characteristic)

expanded-uuids:
  script := [
    [#[0x10, 1, 0, 0xff, 0xff, 0, 0x28], (#[0x11, 20, 1, 0, 4, 0] + (expanded 0x1801))],
    [#[0x10, 5, 0, 0xff, 0xff, 0, 0x28], #[1, 0x10, 5, 0, 0x0a]],
    [#[8, 1, 0, 4, 0, 3, 0x28], (#[9, 21, 2, 0, 0x20, 3, 0] + (expanded 0x2a05))],
    [#[8, 3, 0, 4, 0, 3, 0x28], #[1, 8, 3, 0, 0x0a]],
    [#[4, 4, 0, 4, 0], (#[5, 2, 4, 0] + (expanded 0x2902))],
    [#[0x12, 4, 0, 2, 0], #[0x13]],
    [#[0x12, 4, 0, 0, 0], #[0x13]],
  ]
  with-peer script: | client/att.Client |
    expect-equals 42 (gatt.with-service-changed client: 42)
  // A vendor UUID with the same short-number bytes is not a Bluetooth alias.
  impostor := expanded 0x1801
  impostor[0] = 0
  with-peer [
    [#[0x10, 1, 0, 0xff, 0xff, 0, 0x28], (#[0x11, 20, 1, 0, 4, 0] + impostor)],
    [#[0x10, 5, 0, 0xff, 0xff, 0, 0x28], #[1, 0x10, 5, 0, 0x0a]],
  ]: | client/att.Client |
    expect-throw "GATT_SERVICE_CHANGED_NOT_FOUND": gatt.with-service-changed client: unreachable

ambiguous-monitor:
  [
    [#[9, 7, 2, 0, 0x20, 3, 0, 5, 0x2a, 5, 0, 0x20, 6, 0, 5, 0x2a], "GATT_DUPLICATE_SERVICE_CHANGED"],
    [#[9, 7, 2, 0, 0x22, 3, 0, 5, 0x2a], "GATT_INVALID_SERVICE_CHANGED"],
  ].do: | entry/List |
    response/ByteArray := entry[0]
    start := response.size == 16 ? 6 : 3
    next := #[8, 0, 0, 7, 0, 3, 0x28]
    next[1] = start
    with-peer [
      [#[0x10, 1, 0, 0xff, 0xff, 0, 0x28], #[0x11, 6, 1, 0, 7, 0, 1, 0x18]],
      [#[0x10, 8, 0, 0xff, 0xff, 0, 0x28], #[1, 0x10, 8, 0, 0x0a]],
      [#[8, 1, 0, 7, 0, 3, 0x28], response],
      [next, #[1, 8, 0, 0, 0x0a]],
    ]: | client/att.Client |
      expect-throw entry[1]: gatt.with-service-changed client: unreachable

malformed-pages:
  service := gatt.Service 1 7 #[1, 0x18]
  [
    [#[9, 0], "GATT_INVALID_RESPONSE"],
    [#[9, 7, 2, 0, 2, 2, 0, 1, 0x2a], "GATT_INVALID_HANDLE_RANGE"],
    [#[9, 7, 2, 0, 2, 8, 0, 1, 0x2a], "GATT_INVALID_HANDLE_RANGE"],
    [#[9, 7, 2, 0, 2, 5, 0, 1, 0x2a, 4, 0, 2, 6, 0, 2, 0x2a], "GATT_INVALID_HANDLE_RANGE"],
  ].do: | entry/List |
    with-peer [[#[8, 1, 0, 7, 0, 3, 0x28], entry[0]]]: | client/att.Client |
      expect-throw entry[1]: gatt.characteristics client service
  characteristic := gatt.Characteristic 2 3 0x10 #[1, 0x2a]
  characteristic.end = 7
  [
    [#[5, 0, 4, 0, 2, 0x29], "GATT_INVALID_RESPONSE"],
    [#[5, 2, 4, 0, 2, 0x29], "GATT_INVALID_RESPONSE"],
    [#[5, 1, 3, 0, 2, 0x29], "GATT_INVALID_HANDLE_RANGE"],
    [#[5, 1, 8, 0, 2, 0x29], "GATT_INVALID_HANDLE_RANGE"],
    [#[5, 1, 4, 0, 2, 0x29, 4, 0, 1, 0x29], "GATT_INVALID_HANDLE_RANGE"],
  ].do: | entry/List |
    with-peer [[#[4, 4, 0, 7, 0], entry[0]]]: | client/att.Client |
      expect-throw entry[1]: gatt.descriptors client characteristic
  with-peer [
    [#[4, 4, 0, 7, 0], #[5, 1, 4, 0, 2, 0x29]],
    [#[4, 5, 0, 7, 0], (#[5, 2, 5, 0] + (expanded 0x2902))],
    [#[4, 6, 0, 7, 0], #[1, 4, 6, 0, 0x0a]],
  ]: | client/att.Client |
    expect-throw "GATT_DUPLICATE_CCCD":
      gatt.with-notifications client characteristic: unreachable
  with-peer [
    [#[4, 4, 0, 7, 0], #[5, 1, 4, 0, 1, 0x29]],
    [#[4, 5, 0, 7, 0], #[1, 4, 5, 0, 0x0a]],
  ]: | client/att.Client |
    expect-throw "GATT_CCCD_NOT_FOUND":
      gatt.with-notifications client characteristic: unreachable
  // Security errors are preserved rather than terminating discovery as empty.
  with-peer [[#[8, 1, 0, 7, 0, 3, 0x28], #[1, 8, 1, 0, 5]]]: | client/att.Client |
    error := catch: gatt.characteristics client service
    expect (error is att.AttributeError and error.security-required)

foreign-records:
  with-peer [
    [#[0x10, 1, 0, 0xff, 0xff, 0, 0x28], #[0x11, 6, 1, 0, 0xff, 0xff, 1, 0x18]],
  ]: | first/att.Client |
    service/gatt.Service := (gatt.services first).first
    expect service.valid
    with-peer []: | second/att.Client |
      expect-throw "GATT_FOREIGN_RECORD": gatt.characteristics second service
      expect service.valid

result-limit:
  script := []
  65.repeat: | index/int |
    handle := index + 1
    request := #[0x10, 0, 0, 0xff, 0xff, 0, 0x28]
    request[1] = handle
    response := #[0x11, 6, 0, 0, 0, 0, 1, 0x18]
    response[2] = handle
    response[4] = handle
    script.add [request, response]
  with-peer script: | client/att.Client |
    expect-throw "GATT_DISCOVERY_LIMIT": gatt.services client
