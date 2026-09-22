// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.bond-flash
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.gatt-server as gatt
import ble.experimental.hci
import ble.experimental.security-owner show Owner
import ble.experimental.transport
import monitor
import .mixed-resume-state as saved

main: run

run --resume-only/bool=false
    --exchange-identities/bool=false
    --namespace/string="toit.test/ble-mixed-resume-001-peer"
    --address/ByteArray=saved.PEER
    --radio/transport.Transport?=null:
  state := saved.State (bond-flash.FlashRecords namespace)
      [saved.S3]
      "PEER"
      --resume-only=resume-only
      --exchange-identities=exchange-identities
  controller := hci.Controller (radio or (esp32.Esp32Transport))
  host/Host? := null
  try:
    with-timeout --ms=300_000:
      info := hci.initialize controller
      if info.address != address: throw "MIXED_RESUME_WRONG_BOARD"
      host = Host controller info state
      database := attributes.Database.with-defaults --name="Toit HCI"
      database.add-service #[0xf0, 0xff]
      value := database.add-characteristic #[0xf2, 0xff] --read --authenticated --value="Toit HCI".to-byte-array
      if value != 12: throw "MIXED_FIXTURE_LAYOUT_CHANGED"
      2.repeat: | cycle/int |
        print "MIXED_SECURE_PEER READY cycle=$cycle"
        link := host.accept #[2, 1, 6] --timeout=(Duration --s=100)
        server := gatt.Server host link database --pairing=host.owner
        ended := monitor.Latch
        worker := task::
          error := catch: server.serve: unreachable
          ended.set (error or true) --exception=(error != null)
        try:
          state.secure host.owner 1
          ended.get
        finally:
          worker.cancel
          server.close
      host.close
      host.wait-closed
      state.check (resume-only ? 0 : 1) (resume-only ? 2 : 1)
      print "MIXED_SECURE_PEER COMPLETE cycles=2"
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
    state.close

class Host extends central.Central:
  state_/saved.State
  local_/ByteArray
  owner/Owner? := null
  constructor controller/hci.Controller info/hci.Capabilities .state_:
    local_ = info.address
    super controller --acl-length=info.acl-length --acl-count=info.acl-count
  on-connected link/central.Link -> none:
    owner = state_.owner this link local_
