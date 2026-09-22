// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.bond
import ble.experimental.bond-resume
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.gatt-server as gatt
import ble.experimental.hci
import ble.experimental.privacy
import ble.experimental.smp-identity show Identity
import monitor

central-address -> ByteArray: return #[0xfe, 0x50, 0xc1, 0xfa, 0x12, 0xf4]
peer-address index/int -> ByteArray:
  return index == 0 ? #[0x2e, 0x76, 0x63, 0xac, 0xcd, 0x98] : #[0xae, 0xe0, 0x60, 0xac, 0xcd, 0x98]

// Public fixture keys and identities. No pairing or production provisioning is
// implied by these seeded, unauthenticated test candidates.
candidate index/int --peripheral/bool=false --private/bool=false -> bond.Candidate:
  local := Identity (private ? central-irk : (ByteArray 16)) central-address 0
  peer := Identity (private ? (peer-irk index) : (ByteArray 16)) (peer-address index) 0
  return bond.Candidate (ByteArray 16 --initial=(42 + index))
      (peripheral ? peer : local)
      (peripheral ? local : peer)
      --no-authenticated

central-irk -> ByteArray: return ByteArray 16 --initial=0xa1
peer-irk index/int -> ByteArray: return ByteArray 16 --initial=(0xb1 + index)
central-rpa sequence/int -> ByteArray:
  return privacy.from-prand central-irk #[0x40, 0x10, sequence + 1]
peer-air-address index/int --phase/int=0 --private/bool=false -> ByteArray:
  if not private: return peer-address index
  return privacy.from-prand (peer-irk index) #[0x40, 0x20 + index, phase + 1]

main: run

run --private/bool=false:
  with-timeout --ms=90_000:
    controller := hci.Controller (esp32.Esp32Transport)
    host/Host? := null
    try:
      info := hci.initialize controller
      index := info.address == (peer-address 0) ? 0 : 1
      if info.address != (peer-address index): throw "REVOKE_PEER_WRONG_BOARD"
      host = Host controller info index --private=private
      database := attributes.Database.with-defaults --name="Toit revoke peer"
      database.add-service #[0xf0, 0xff]
      value := database.add-characteristic #[0xf1, 0xff] --read --encrypted --value=#[42 + index]
      (index == 0 ? 2 : 1).repeat: | phase/int |
        local := private and (peer-air-address index --phase=phase --private)
        print "REVOKE_PEER READY peer=$index phase=$phase private=$private address=$local"
        link := host.accept #[2, 1, 6, 3, 3, 0xf0, 0xff]
            --local-random-address=local
        if private and (link.info.address-type != 1 or not (privacy.resolves central-irk link.info.address 1)):
          throw "REVOKE_PEER_CENTRAL_IDENTITY"
        owner := host.owner
        server := gatt.Server host link database --pairing=owner
        ended := monitor.Latch
        worker := task::
          error := catch: server.serve: unreachable
          ended.set error
        try:
          error := catch: owner.run
          if phase == 0:
            if error: throw error
            if not owner.encrypted or owner.authenticated: throw "REVOKE_PEER_SECURITY"
            print "REVOKE_PEER ENCRYPTED peer=$index handle=$value"
          else:
            if not error or link.encrypted: throw "REVOKE_PEER_DENIAL_MISSING"
            print "REVOKE_PEER DENIED peer=$index error=$error encrypted=false"
          failure := ended.get
          if failure: throw failure
        finally:
          worker.cancel
          server.close
      print "REVOKE_PEER COMPLETE peer=$index"
    finally:
      if host:
        host.close
        host.wait-closed
      else:
        controller.close
        controller.wait-closed

class Host extends central.Central:
  local_/ByteArray
  candidate_/bond.Candidate
  owner/bond-resume.Resume? := null
  constructor controller/hci.Controller info/hci.Capabilities index/int --private/bool=false:
    local_ = info.address.copy
    candidate_ = candidate index --peripheral --private=private
    super controller --acl-length=info.acl-length --acl-count=info.acl-count
  on-connected link/central.Link -> none:
    owner = bond-resume.Resume this link candidate_ --local-address=(link.local-random-address or local_)
