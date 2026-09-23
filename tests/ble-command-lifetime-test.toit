// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.hci
import expect show *
import monitor
import system
import .ble-fixture as fixture
import .ble-checked-send-test as held

main:
  4.repeat: | mode/int | run mode

run mode/int:
  with-timeout --ms=5_000:
    radio := held.HeldTransport
    radio.auto-disconnect = true
    host := central.Central (hci.Controller radio)
    client/att.Client? := null
    responder := task::
      fixture.status-reply radio fixture.create-command
      radio.received.add fixture.connection-event
      if mode >= 2:
        fixture.gatt-reply radio #[0x12, 9, 0, 2, 0] #[0x13]
    try:
      link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
      client = att.Client host link
      if mode >= 2:
        failure := catch:
          client.monitor-service-changed 8 --cccd=9:
            exercise radio client mode
        expect-equals (mode == 2 ? "HCI_ACL_SEND_ABORTED" : "ATT_REQUEST_ABORTED") failure
      else:
        exercise radio client mode
    finally:
      if client: client.close
      responder.cancel
      host.close
      host.wait-closed

exercise radio/held.HeldTransport client/att.Client mode/int:
  radio.hold = true
  value := #[7, 8, 9]
  revision := client.database-revision
  ended := monitor.Latch
  failure := null
  sender := task::
    try:
      failure = catch:
        if mode == 3:
          client.read 3
        else:
          client.write-command 3 value --database-revision=revision
    finally:
      critical-do --no-respect-deadline: ended.set true
  try:
    radio.entered.get
    count := radio.sent-count
    value.fill 0xff
    system.process-stats --gc
    if mode == 1:
      sender.cancel
    else:
      if mode >= 2:
        radio.received.add (fixture.att-event #[0x1d, 8, 0, 1, 0, 0xff, 0xff])
        while client.valid-database-revision revision: yield
      radio.release.set true
    ended.get
    if mode == 0:
      expect-null failure
      fixture.att-sent radio #[0x52, 3, 0, 7, 8, 9]
      expect (not radio.closed)
    else:
      if mode >= 2: expect-equals "GATT_DATABASE_CHANGED" failure
      expect-equals count radio.sent-count
      expect (not radio.closed)
  finally:
    sender.cancel
