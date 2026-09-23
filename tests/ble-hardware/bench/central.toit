// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The central for the memory comparison, on a Linux adapter with the Toit
// host: connects to the peripheral, subscribes, counts notifications for a
// fixed window, disconnects, and repeats.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.gatt
import ble.experimental.hci
import ble.experimental.linux
import encoding.hex
import .uuids as uuids

WINDOW ::= Duration --s=5

main args/List:
  if not 2 <= args.size <= 3: throw "Usage: central.toit <adapter index> <peer address hex> [cycles]"
  address := (hex.decode args[1]).reverse
  if address.size != 6: throw "INVALID_ADDRESS"
  cycles := args.size == 3 ? (int.parse args[2]) : 10
  controller := hci.Controller (linux.LinuxTransport (int.parse args[0]))
  host/central.Central? := null
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --receive-limit=247
        --early-acl-timeout=(Duration --ms=20)
    cycles.repeat: | cycle/int |
      started := Time.monotonic-us
      link := host.connect address --address-type=0 --timeout=(Duration --s=30)
      client := att.Client host link --mtu-limit=247
      count := 0
      bytes := 0
      elapsed := 0
      mtu := 23
      error := catch:
        mtu = client.exchange-mtu
        host.update-parameters link --interval-min=6 --interval-max=12
        service := gatt.services client
        service = service.filter: it.uuid == uuids.SERVICE
        if service.size != 1: throw "BENCH_SERVICE_NOT_FOUND"
        characteristics := (gatt.characteristics client service[0]).filter: it.uuid == uuids.VALUE
        if characteristics.size != 1: throw "BENCH_VALUE_NOT_FOUND"
        characteristic/gatt.Characteristic := characteristics[0]
        descriptors := (gatt.descriptors client characteristic).filter: it.uuid == #[0x02, 0x29]
        if descriptors.size != 1: throw "BENCH_CCCD_NOT_FOUND"
        connected := Time.monotonic-us - started
        length := link.data-length
        print "BENCH central cycle=$cycle connected-us=$connected mtu=$mtu interval=$link.parameters.interval tx-octets=$(length ? length.tx-octets : 27) rx-octets=$(length ? length.rx-octets : 27)"
        client.subscribe characteristic.handle --cccd=descriptors[0].handle --queue-limit=32: | stream/att.Subscription |
          first := with-timeout --ms=10_000: stream.receive
          count = 1
          bytes = first.size
          begin := Time.monotonic-us
          deadline := begin + WINDOW.in-us
          while true:
            remaining := deadline - Time.monotonic-us
            if remaining <= 0: break
            packet/ByteArray? := null
            expired := catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
              packet = with-timeout (Duration --us=remaining): stream.receive
            if expired: break
            count++
            bytes += packet.size
          elapsed = Time.monotonic-us - begin
      client.close
      catch: host.disconnect link
      reason := catch: link.wait-disconnected
      rate := elapsed > 0 ? count * 1_000_000 / elapsed : 0
      print "BENCH central cycle=$cycle notifications=$count bytes=$bytes us=$elapsed per-second=$rate error=$error"
      sleep --ms=500
    print "BENCH central done cycles=$cycles"
  finally:
    if host: host.close
    controller.close
