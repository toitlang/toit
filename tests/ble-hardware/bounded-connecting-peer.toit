// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.hci
import ble.experimental.transport
import .bounded-radio as fixture

main: run

run --canceled-first/bool=false:
  run-with-transport (esp32.Esp32Transport) #[0xa9, 0x56, 0xa3, 0x4b, 0x88, 0x8a]
      --canceled-first=canceled-first

run-with-transport radio/transport.Transport peer/ByteArray --canceled-first/bool=false:
  controller := hci.Controller radio
  host/TrackingCentral? := null
  try:
    info := hci.initialize controller
    host = TrackingCentral controller --acl-length=info.acl-length --acl-count=info.acl-count
    if canceled-first:
      error := catch:
        host.connect peer --address-type=0 --timeout=(Duration --s=30)
      if error and error != "HCI_CONNECTION_LOST": throw error
      if not host.first-link: throw "WINNER_CONNECTION_NOT_OBSERVED"
      reason := with-timeout --ms=5_000: host.first-link.wait-disconnected
      if reason != 0x13: throw "WINNER_DISCONNECT_REASON"
      print "BOUNDED_CONNECTOR WINNER_DISCONNECTED reason=$reason"
    2.repeat: | cycle/int |
      link := host.connect peer --address-type=0 --timeout=(Duration --s=30)
      client := att.Client host link
      try:
        fixture.read-values client
        host.disconnect link
        link.wait-disconnected
      finally:
        client.close
      print "BOUNDED_CONNECTOR cycle=$cycle reads=100"
    print "BOUNDED_CONNECTOR COMPLETE reads=200"
    if canceled-first and (host.first-link.connected or not host.first-link.has-ended):
      throw "WINNER_LIFETIME_REUSED"
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed

class TrackingCentral extends central.Central:
  first-link/central.Link? := null

  constructor controller/hci.Controller --acl-length/int --acl-count/int:
    super controller --acl-length=acl-length --acl-count=acl-count

  on-connected link/central.Link -> none:
    if not first-link: first-link = link
