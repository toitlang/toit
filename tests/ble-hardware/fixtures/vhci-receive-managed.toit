// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.hci
import io
import system
import .vhci-receive-window as window

main: run --receiver --peer-address=#[0x3a, 0x0b, 0xa0, 3, 0xf7, 0x84]

// Uses production Controller/Central accounting, without a counting transport.
run --receiver/bool --peer-address/ByteArray:
  radio := esp32.Esp32Transport
  controller := hci.Controller radio
  host/central.Central? := null
  try:
    info := hci.initialize controller --receive-acl-packets=(receiver ? 4 : 0)
    host = central.Central controller --acl-length=27 --acl-count=info.acl-count --receive-limit=1024
    print "RX_MANAGED READY receiver=$receiver"
    link := receiver
        ? (host.connect peer-address --address-type=0)
        : (host.accept #[2, 1, 6])
    if link.info.address-type != 0 or link.info.address != peer-address:
      throw "RX_MANAGED_UNEXPECTED_PEER"
    with-timeout --ms=90_000:
      if receiver:
        retained := []
        before := system.process-stats
        host.send link 4 window.START
        8.repeat: | burst/int |
          8.repeat: | index/int |
            sequence := burst * 8 + index
            bytes := window.require-payload link (payload sequence)
            retained.add [sequence, bytes]
            if retained.size > 4: retained.remove --at=0
            system.process-stats --gc
            retained.do: | item/List |
              if item[1] != (payload item[0]): throw "RX_MANAGED_RETAINED_DATA_CHANGED"
          host.send link 4 (barrier burst)
        window.require-payload link window.ACK
        after := system.process-stats
        gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
        compacting := after[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT] - before[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT]
        if gcs < 64: throw "RX_MANAGED_EXPECTED_GC"
        sample := radio.diagnostics
        if not sample or sample.fault: throw "RX_MANAGED_TRANSPORT_FAULT"
        host.disconnect link
        print "RX_MANAGED_RECEIVER COMPLETE values=64 bytes=32768 retained=4 full-gcs=$gcs compacting-gcs=$compacting high-water=$(sample.high-water) capacity=$(sample.capacity)"
      else:
        window.require-payload link window.START
        8.repeat: | burst/int |
          8.repeat: | index/int | host.send link 4 (payload (burst * 8 + index))
          window.require-payload link (barrier burst)
        host.send link 4 window.ACK
        with-timeout --ms=3_000: link.wait-disconnected
        print "RX_MANAGED_SENDER COMPLETE acknowledged=64 bytes=32768"
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed

payload sequence/int -> ByteArray:
  bytes := ByteArray 512: (sequence + it) % 251
  io.LITTLE-ENDIAN.put-uint32 bytes 0 sequence
  return bytes

barrier burst/int -> ByteArray: return #[0x52, 1, 0, burst]
