// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.advertising
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.linux
import ble.experimental.scanning
import encoding.hex
import uuid

main args/List:
  if not 1 <= args.size <= 4:
    throw "Usage: hci-connect.toit <adapter index> [cycle count] [connected milliseconds] [service UUID]"
  cycles := args.size >= 2 ? (int.parse args[1]) : 1
  connected-ms := args.size >= 3 ? (int.parse args[2]) : 0
  if not 1 <= cycles <= 1000: throw "INVALID_ARGUMENT"
  if not 0 <= connected-ms <= 10_000: throw "INVALID_ARGUMENT"
  service-id := args.size == 4 ? args[3] : "9f6c1000-8e2a-4b13-9e97-94f353eeb001"
  service := (uuid.Uuid.parse service-id).to-byte-array.reverse
  controller := hci.Controller (linux.LinuxTransport (int.parse args[0]))
  host/central.Central? := null
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --early-acl-timeout=(Duration --ms=20)
    cycles.repeat: | cycle/int |
      peer/advertising.Report? := null
      with-timeout --ms=10_000:
        scanning.scan controller --active: | report/advertising.Report |
          if not (report.has-service service): continue.scan true
          peer = report
          false
      print "cycle=$(cycle + 1) peer=$(hex.encode peer.address.reverse) type=$(peer.address-type) rssi=$(peer.rssi)"
      link := host.connect peer.address --address-type=peer.address-type
      print "connected handle=$(link.info.handle) interval=$(link.info.interval)"
      if connected-ms > 0: sleep --ms=connected-ms
      host.disconnect link
      print "disconnected reason=$(link.wait-disconnected)"
  finally:
    if host: host.close
    else: controller.close
