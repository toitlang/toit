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
import ble.experimental.native
import ble.experimental.security
import ble.experimental.security-owner show Owner
import monitor
import .vhci-bond-revocation-peer as fixture

main: run

run --first-peer/ByteArray?=null --receive-acl-packets/int=0:
  with-timeout --ms=150_000:
    radio := ShutdownRadio
    controller := hci.Controller radio
    host/Host? := null
    try:
      info := hci.initialize controller --receive-acl-packets=receive-acl-packets
      first := first-peer or (fixture.peer-address 0)
      index := info.address == first ? 0 : 1
      if info.address != (index == 0 ? first : (fixture.peer-address 1)):
        throw "REVOKE_AUTH_WRONG_BOARD"
      host = Host controller info
      database := attributes.Database.with-defaults --name="Toit auth revoke"
      database.add-service #[0xf0, 0xff]
      value := database.add-characteristic #[0xf1, 0xff] --read --authenticated --value=#[42 + index]
      if value != 12: throw "REVOKE_AUTH_HANDLE"
      (index == 0 ? 3 : 2).repeat: | phase/int |
        print "REVOKE_AUTH READY peer=$index phase=$phase"
        link := host.accept #[2, 1, 6, 3, 3, 0xf0, 0xff] --timeout=(Duration --s=120)
        owner/Owner := phase == 0
            ? (security.Pairing host link --local-address=info.address --io-capability=1 --require-authentication --bond)
            : host.owner
        server := gatt.Server host link database --pairing=owner
        ended := monitor.Latch
        worker := task::
          error := catch: server.serve: unreachable
          ended.set error
        try:
          error := catch:
            if phase == 0:
              (owner as security.Pairing).run
                  (: | number/int |
                    print "REVOKE_AUTH NUMERIC peer=$index value=$number fixture-approval=true"
                    true)
                  --candidate=: | saved/bond.Candidate |
                    if not saved.authenticated or saved.peer.address != fixture.central-address:
                      throw "REVOKE_AUTH_BAD_CANDIDATE"
                    host.saved = saved
            else:
              (owner as bond-resume.Resume).run
          if phase < 2:
            if error: throw error
            if not owner.encrypted or not owner.authenticated: throw "REVOKE_AUTH_SECURITY"
            print "REVOKE_AUTH ENCRYPTED peer=$index phase=$phase authenticated=true"
          else:
            if not error or link.encrypted: throw "REVOKE_AUTH_DENIAL_MISSING"
            print "REVOKE_AUTH DENIED peer=$index error=$error encrypted=false"
          failure := ended.get
          if failure: throw failure
        finally:
          worker.cancel
          server.close
      print "REVOKE_AUTH COMPLETE peer=$index"
    finally:
      if host:
        host.close
        host.wait-closed
      else:
        controller.close
        controller.wait-closed
      radio.dump

class Host extends central.Central:
  local_/ByteArray
  saved/bond.Candidate? := null
  owner/bond-resume.Resume? := null
  constructor controller/hci.Controller info/hci.Capabilities:
    local_ = info.address.copy
    super controller --acl-length=info.acl-length --acl-count=info.acl-count
  on-connected link/central.Link -> none:
    if saved:
      owner = bond-resume.Resume this link saved --local-address=local_ --require-authentication

// Sample only at shutdown; do not override receive, send, or connection hooks.
class ShutdownRadio extends esp32.Esp32Transport:
  sampled_/bool := false
  sample_/native.QueueDiagnostics? := null
  error_ := null
  constructor: super
  close -> none:
    if not sampled_:
      sampled_ = true
      error_ = catch: sample_ = diagnostics
    super
  dump -> none:
    if sample_:
      print "REVOKE_QUEUE queued=$sample_.queued high-water=$sample_.high-water drops=$sample_.scan-drops fault=$sample_.fault"
    else:
      print "REVOKE_QUEUE unavailable=true error=$error_"
