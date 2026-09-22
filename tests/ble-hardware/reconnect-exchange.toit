// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.


import ble.experimental.advertising
import ble.experimental.att
import ble.experimental.central
import ble.experimental.gatt
import ble.experimental.hci
import ble.experimental.scanning
import .fixtures.hci-echo as fixture

exchange controller/hci.Controller host/central.Central cycle/int --peer-address/ByteArray?=null -> none:
  exchange controller host cycle --peer-address=peer-address: | _ | null

// The diagnostic block runs before constructing the ATT client. Keep it scoped
// so a probe needs neither an escaping callback nor another task.
exchange controller/hci.Controller host/central.Central cycle/int --peer-address/ByteArray?=null
    [before-att] -> none:
  service-uuid := fixture.wire-uuid "9f6c1000-8e2a-4b13-9e97-94f353eeb001"
  peer/advertising.Report? := null
  with-timeout --ms=10_000:
    scanning.scan controller --active: | report/advertising.Report |
      if not (report.has-service service-uuid): continue.scan true
      if peer-address and (report.address-type != 0 or report.address != peer-address):
        continue.scan true
      peer = report
      false
  link := host.connect peer.address --address-type=peer.address-type
  connected-at := Time.monotonic-us
  client/att.Client? := null
  completed := false
  try:
    before-att.call link
    client = att.Client host link
    service/gatt.Service := fixture.find-uuid (gatt.services client) service-uuid
    characteristics := gatt.characteristics client service
    input/gatt.Characteristic := fixture.find-uuid characteristics (fixture.wire-uuid "9f6c1001-8e2a-4b13-9e97-94f353eeb001")
    echo/gatt.Characteristic := fixture.find-uuid characteristics (fixture.wire-uuid "9f6c1002-8e2a-4b13-9e97-94f353eeb001")
    client.read echo.handle
    gatt.with-notifications client echo: | subscription/att.Subscription |
      10.repeat: | index/int |
        value := fixture.payload (cycle * 10 + index)
        client.write input.handle value
        actual := with-timeout --ms=3_000: subscription.receive
        if actual != value: throw "RECONNECT_ECHO_MISMATCH"
        // Keep each connection active for useful traffic rather than exercising
        // the separately tracked immediate-disconnect interoperability failure.
        sleep --ms=100
      if subscription.dropped != 0: throw "RECONNECT_NOTIFICATION_OVERFLOW"
    if (client.read echo.handle) != (fixture.payload (cycle * 10 + 9)):
      throw "RECONNECT_READ_MISMATCH"
    host.disconnect link
    completed = true
  finally:
    if not completed:
      // Observe the already-latched termination before local cleanup can alter
      // the link. Never wait for a future event or replace the original error
      // if optional diagnostic output itself fails.
      catch: report-failed-link link cycle (Time.monotonic-us - connected-at)
    if client: client.close

report-failed-link link/central.Link cycle/int elapsed-us/int -> none:
  ended := link.has-ended
  reason/int? := null
  cause := null
  if ended:
    cause = catch: reason = link.wait-disconnected
  print "RECONNECT_FAILURE cycle=$cycle handle=$(link.info.handle) interval=$(link.info.interval) elapsed-us=$elapsed-us ended=$ended reason=$reason cause=$cause"
