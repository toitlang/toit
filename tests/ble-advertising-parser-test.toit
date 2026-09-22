// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system
import ble.experimental.advertising as advertising

main:
  256.repeat: | flags/int |
    expect-equals (flags & 1 != 0)
        advertising.has-limited-discoverable-flags #[2, 1, flags]
  [#[], #[1, 1], #[2, 1], #[2, 1, 1, 2], #[2, 1, 1, 2, 1, 1]].do: | data/ByteArray |
    expect (not (advertising.has-limited-discoverable-flags data))
  expect (advertising.has-limited-discoverable-flags #[2, 1, 1, 0, 255])
  // A valid first report must never escape when a later report is malformed.
  base := #[4, 0x3e, 22, 2, 2] + (record 0) + (record 1)
  base.size.repeat: | size/int |
    truncated := base[0..size].copy
    if size >= 3: truncated[2] = size - 3
    check-packet truncated --must-fail
  256.repeat: | count/int |
    packet := base.copy
    packet[4] = count
    check-packet packet --must-fail=(count != 2)
  256.repeat: | length/int |
    packet := base.copy
    packet[23] = length
    check-packet packet --must-fail=(length != 0)

  // All RSSI octets, maximum report count and retained managed slices.
  256.repeat: | raw/int |
    packet := #[4, 0x3e, 12, 2, 1] + (record 0)
    packet[14] = raw
    advertising.reports-do packet: | report |
      signed := raw < 128 ? raw : raw - 256
      expect-equals (-127 <= signed <= 20 ? signed : null) report.rssi
  maximum-data := ByteArray 31: it
  maximum := #[4, 0x3e, 43, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 31] + maximum-data + #[127]
  expect (advertising.reports-do maximum: | report |
    expect-equals maximum-data report.data)
  oversized := maximum + #[0]
  oversized[2]++
  oversized[13] = 32
  check-packet oversized --must-fail
  largest := #[4, 0x3e, 252, 2, 25]
  25.repeat: largest += (record it)
  retained := []
  expect (advertising.reports-do largest: retained.add it)
  system.process-stats --gc
  expect-equals 25 retained.size
  25.repeat: | index/int |
    expect-equals (ByteArray 6 --initial=index) retained[index].address
    expect-equals #[] retained[index].data

  // Fixed-seed mutations favor internally malformed report events, instead of
  // spending nearly every case on an unsupported outer packet type.
  random := Generator
  10_000.repeat: | index/int |
    packet := (index % 2 == 0 ? base : largest).copy
    position := random.next % packet.size
    packet[position] = random.next & 0xff
    if index % 3 == 0:
      packet = packet[0..random.next % (packet.size + 1)].copy
    if packet.size >= 3: packet[2] = packet.size - 3
    check-packet packet

record index/int -> ByteArray:
  return #[index % 5, index % 2] + (ByteArray 6 --initial=index) + #[0, 127]

check-packet packet/ByteArray --must-fail/bool=false:
  delivered := 0
  matched := false
  failure := catch:
    matched = advertising.reports-do packet: | report |
      delivered++
      expect-equals 6 report.address.size
      expect (report.data.size <= 31)
      expect (report.rssi == null or -127 <= report.rssi <= 20)
  if failure:
    expect (failure == "HCI_MALFORMED_PACKET" or
        failure == "HCI_UNSUPPORTED_PACKET_TYPE" or
        failure == "HCI_MALFORMED_ADVERTISING_REPORT")
    expect-equals 0 delivered
  else:
    expect (not must-fail)
    if matched: expect-equals packet[4] delivered
    else: expect-equals 0 delivered

class Generator:
  state/int := 130_013
  next -> int:
    state = (1664525 * state + 1013904223) & 0xffff_ffff
    return state
