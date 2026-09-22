// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.gatt-server as gatt
import ble.experimental.hci
import monitor
import system
import .mixed-provider-death-peer as fixture
import .mixed-resume-peer as resume
import .mixed-resume-state as saved

main:
  with-timeout --ms=160_000: run

run --state/saved.State?=null:
  controller := hci.Controller fixture.Radio
  host/central.Central? := null
  try:
    info := hci.initialize controller
    if state and info.address != saved.PEER: throw "MIXED_RESUME_WRONG_BOARD"
    host = state
        ? (resume.Host controller info state)
        : (central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count)
    database := attributes.Database.with-defaults --name="Toit HCI"
    database.add-service #[0xf0, 0xff]
    value := database.add-characteristic #[0xf1, 0xff] --read --notify --dynamic-read --value=#[77]
        --authenticated=(state != null)
    if value != 12: throw "MIXED_FIXTURE_LAYOUT_CHANGED"
    2.repeat: | cycle/int |
      print "GATT_SERVER READY cycle=$cycle"
      link := host.accept #[2, 1, 6] --timeout=(Duration --s=60)
      server := gatt.Server host link database --handler-timeout=(Duration --s=10)
          --pairing=(state ? (host as resume.Host).owner : null)
      pending := false
      unwound := monitor.Latch
      ended := monitor.Latch
      worker := task::
        error/any := null
        try:
          error = catch:
            server.serve-with-requests
                (: | request/attributes.ReadRequest |
                  if cycle != 0 or request.handle != value or pending: throw "MIXED_UNEXPECTED_READ"
                  pending = true
                  system.process-stats --gc
                  if not (server.notify value): throw "MIXED_PENDING_NOT_SUBSCRIBED"
                  print "MIXED_PROVIDER_PENDING PEER_READ_WAITING marker=77"
                  try:
                    (monitor.Latch).get
                  finally:
                    critical-do --no-respect-deadline: unwound.set true)
                (: | request | request.reject 0x0e)
                (: | handle/int bytes/ByteArray |
                  if handle != 13 or bytes != #[1, 0]: throw "MIXED_UNEXPECTED_CCCD")
        finally:
          critical-do --no-respect-deadline:
            ended.set (error or true) --exception=(error != null)
      try:
        if state: state.secure (host as resume.Host).owner 1
        reason := link.wait-disconnected
        with-timeout --ms=3_000: ended.get
        if pending != (cycle == 0): throw "MIXED_PENDING_COUNT"
        if pending and not unwound.has-value: throw "MIXED_PEER_HANDLER_NOT_UNWOUND"
        print "MIXED_PROVIDER_PENDING PEER_CYCLE cycle=$cycle pending=$pending reason=$reason"
      finally:
        worker.cancel
        server.close
    host.close
    host.wait-closed
    if state: state.check 0 2
    print "VHCI_RECONNECT COMPLETE cycles=2 pending-read=true"
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
