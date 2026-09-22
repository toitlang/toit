// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.bond
import ble.experimental.bond-flash
import ble.experimental.bond-storage
import ble.experimental.bond-resume
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.gatt-server
import ble.experimental.hci
import ble.experimental.privacy
import ble.experimental.smp-identity
import encoding.hex
import ble.experimental.security
import ble.experimental.security-owner show Owner
import monitor
import system
import .hci-echo as fixture
import .vhci-pairing show PairingTrace

main:
  run

run --numeric/bool=false --private/bool=false
    --storage-path/string="toit.test/ble-reconnect"
    --reference-address/ByteArray=#[0xc2, 0xda, 0x2a, 0xac, 0xbe, 8]
    --expected-resume/bool?=null --receive-acl-packets/int=0
    --service-uuid/string="9f6c4000-8e2a-4b13-9e97-94f353eeb001":
  // Public fixture key, stored separately from the protected candidate bytes.
  store := bond-storage.Storage (bond-flash.FlashRecords storage-path) (ByteArray 32: it)
  controller := hci.Controller (PairingTrace (esp32.Esp32Transport))
  host/PreparedHost? := null
  server/gatt-server.Server? := null
  worker/Task? := null
  try:
    saved := store.load #[1]
    if expected-resume != null and (saved != null) != expected-resume:
      throw "BLE_BOND_RECONNECT_WRONG_PHASE"
    info := hci.initialize controller --receive-acl-packets=receive-acl-packets
    if controller.receive-flow-control != (receive-acl-packets != 0):
      throw "BLE_BOND_RECONNECT_RECEIVE_FLOW_MISMATCH"
    print "BLE_BOND_RECONNECT RECEIVE_FLOW packets=$receive-acl-packets"
    host = PreparedHost controller info saved --require-authentication=numeric
    local-identity := private
        ? (smp-identity.Identity (hex.decode "ec0234a357c8ad05341010a60a397d9b") info.address 0)
        : null
    local-random := private and saved ? (privacy.generate saved.local.irk) : null
    if local-random:
      if not saved.local.has-resolving-key: throw "MISSING_LOCAL_IRK"
      print "BLE_BOND_RECONNECT RPA address=$(hex.encode local-random.reverse)"
    database := attributes.Database.with-defaults --name="Toit SC bond"
    uuid := fixture.wire-uuid service-uuid
    database.add-service uuid
    database.add-characteristic (fixture.wire-uuid "9f6c4001-8e2a-4b13-9e97-94f353eeb001")
        --read
        --encrypted
        --value=#[42]
    database.add-characteristic (fixture.wire-uuid "9f6c4002-8e2a-4b13-9e97-94f353eeb001")
        --read
        --authenticated
        --value=#[43]
    print "BLE_BOND_RECONNECT READY mode=$(saved ? "resume" : "pair")"
    link := host.accept (#[2, 1, 6, 17, 7] + uuid) --timeout=(Duration --s=60)
        --local-random-address=local-random
    owner/Owner := saved ? host.resume : (security.Pairing host link --local-address=info.address
        --io-capability=(numeric ? 1 : 3)
        --require-authentication=numeric
        --bond
        --identity=local-identity)
    server = gatt-server.Server host link database --pairing=owner
    ended := monitor.Latch
    worker = task::
      error := catch: server.serve: unreachable
      ended.set error
    with-timeout --ms=45_000:
      if saved:
        (owner as bond-resume.Resume).run
      else:
        (owner as security.Pairing).run (: | number/int | confirm numeric number) --candidate=: | candidate/bond.Candidate |
          if candidate.peer.address-type != 0 or candidate.peer.address != reference-address:
            throw "UNEXPECTED_REFERENCE_IDENTITY"
          store.save #[1] candidate
          print "BLE_BOND_RECONNECT candidate-saved=true"
    system.process-stats --gc
    print "BLE_BOND_RECONNECT ENCRYPTED resumed=$(saved != null) authenticated=$(owner.authenticated)"
    error := with-timeout --ms=50_000: ended.get
    if error: throw error
    if saved:
      store.remove #[1]
      print "BLE_BOND_RECONNECT candidate-deleted=true"
    print "BLE_BOND_RECONNECT COMPLETE"
  finally:
    if worker: worker.cancel
    if server: server.close
    if host:
      host.close
      host.wait-closed
    controller.close
    controller.wait-closed
    store.close

class PreparedHost extends central.Central:
  local_/ByteArray
  saved_/bond.Candidate?
  require-authentication_/bool
  resume/bond-resume.Resume? := null

  constructor controller/hci.Controller info/hci.Capabilities .saved_ --require-authentication/bool:
    require-authentication_ = require-authentication
    local_ = info.address.copy
    super controller --acl-length=info.acl-length --acl-count=info.acl-count

  on-connected link/central.Link -> none:
    if saved_:
      resume = bond-resume.Resume this link saved_ --local-address=(link.local-random-address or local_)
          --require-authentication=require-authentication_

confirm numeric/bool number/int -> bool:
  if not numeric: throw "UNEXPECTED_NUMERIC_COMPARISON"
  // Public fixture approval; the independent agent checks its own number.
  print "VHCI_PAIRING NUMERIC value=$number fixture-approval=true"
  return true
