// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.bounded-central as bounded
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.service.mixed-provider as mixed
import io
import system
import .establishment-idle as idle

main:
  with-timeout --ms=40_000:
    run --inject
    // The peer's controller needs its four-second supervision timeout after
    // our controller is closed. This is fixture coordination, not a host retry.
    sleep --ms=5_000
    run --no-inject
    print "BOUNDED_FAILURE COMPLETE reads=120 opens=2 closes=2"

run --inject/bool:
  radio := Radio --inject=inject
  controller := hci.Controller radio
  host/bounded.Central? := null
  client/att.Client? := null
  try:
    info := hci.initialize controller --receive-acl-packets=4
    mixed.configure controller info
    host = bounded.Central controller --acl-length=info.acl-length
        --acl-count=info.acl-count
        --receive-limit=517
        --link-limit=2
    link := host.connect #[0xae, 0xe0, 0x60, 0xac, 0xcd, 0x98]
        --address-type=0
        --timeout=(Duration --s=8)
    client = att.Client host link
    reads := inject ? 100 : 20
    retained := []
    before := system.process-stats
    reads.repeat: | index/int |
      value := client.read 3
      if value != #[index & 0xff, index >> 8, 42]: throw "BOUNDED_FAILURE_VALUE"
      if retained.size < 4: retained.add value
      if index % 10 == 0: system.process-stats --gc
    retained.size.repeat:
      if retained[it] != #[it, 0, 42]: throw "BOUNDED_FAILURE_RETAINED"
    after := system.process-stats
    gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if gcs < reads / 10: throw "BOUNDED_FAILURE_GC"
    print "BOUNDED_FAILURE READS inject=$inject reads=$reads retained=4 full-gcs=$gcs"
    if inject:
      failure := catch: host.accept #[2, 1, 6] --timeout=(Duration --s=5)
      elapsed := Time.monotonic-us - radio.injected-us
      if failure != "HCI_UNEXPECTED_ADVERTISING_TERMINATION" or radio.injected-us == 0 or
          not 0 < elapsed < 1_000_000:
        throw "BOUNDED_FAILURE_WAKEUP"
      if not link.has-ended or (catch: link.wait-disconnected) != failure:
        throw "BOUNDED_FAILURE_SURVIVOR"
      host.wait-closed
      if radio.closes != 1 or radio.sends-after-fault != 0 or radio.acl-sent != 100:
        throw "BOUNDED_FAILURE_CLEANUP"
      print "BOUNDED_FAILURE FAULT error=$failure elapsed-us=$elapsed close-us=$(radio.closed-us - radio.injected-us) closes=1 sends-after-fault=0 actual-status=$(radio.actual-status) actual-set=$(radio.actual-set) delivered-set=1"
    else:
      host.disconnect link
      if link.wait-disconnected != 0x16 or radio.injected-us != 0 or radio.acl-sent != 20:
        throw "BOUNDED_FAILURE_RECOVERY"
  finally:
    critical-do --no-respect-deadline:
      if client: client.close
      if host:
        host.close
        host.wait-closed
      else:
        controller.close
        controller.wait-closed
      radio.dump
  if radio.closes != 1: throw "BOUNDED_FAILURE_LIFETIME"
  print "BOUNDED_FAILURE CLOSED inject=$inject closes=1"

// Corrupts only the set identifier of one actual successful expiry event.
// No synthetic event replaces the controller's advertising-window timing.
class Radio extends idle.Radio:
  inject_/bool
  injected-us/int := 0
  closed-us/int := 0
  closes/int := 0
  sends-after-fault/int := 0
  actual-status/int := -1
  actual-set/int := -1

  constructor --inject/bool:
    inject_ = inject
    super

  receive -> ByteArray:
    packet := super
    if inject_ and packet.size == 9 and packet[0] == 4 and
        packet[1] == 0x3e and packet[3] == 0x12:
      if injected-us != 0: throw "BOUNDED_FAILURE_REPEATED_TERMINATION"
      actual-status = packet[4]
      actual-set = packet[5]
      if actual-status != 0x3c or actual-set != 0: throw "BOUNDED_FAILURE_UNEXPECTED_TERMINATION"
      packet = packet.copy
      packet[5] = 1
      injected-us = Time.monotonic-us
    return packet

  record-send packet/ByteArray -> none:
    super packet
    if injected-us != 0:
      if packet[0] != 1 or (io.LITTLE-ENDIAN.uint16 packet 1) != 0x0c35:
        sends-after-fault++

  close -> none:
    if closes != 0: return
    closes++
    super
    closed-us = Time.monotonic-us
