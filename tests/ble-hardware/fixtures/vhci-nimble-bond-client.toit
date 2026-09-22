// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.att
import ble.experimental.bond
import ble.experimental.bond-flash
import ble.experimental.bond-storage
import ble.experimental.bond-resume
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.gatt
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.security-owner show Owner
import encoding.hex
import system
import .hci-echo as fixture

main: run

run --forget/bool=false --resume-only/bool=false --receive-acl-packets/int=0:
  if forget and resume-only: throw "INVALID_ARGUMENT"
  with-timeout --ms=60_000:
    // Public fixture protection key; never use it for deployed bond storage.
    store := bond-storage.Storage
        bond-flash.FlashRecords "toit.test/nimble-central-resume-v1"
        ByteArray 32: it
    controller := hci.Controller (esp32.Esp32Transport)
    host/central.Central? := null
    client/att.Client? := null
    try:
      if forget:
        store.remove #[1]
        print "NIMBLE_CENTRAL FIXTURE_BOND_REMOVED"
      saved := store.load #[1]
      if resume-only and not saved: throw "EXPECTED_SAVED_FIXTURE_BOND"
      info := hci.initialize controller --receive-acl-packets=receive-acl-packets
      if controller.receive-flow-control != (receive-acl-packets != 0):
        throw "RECEIVE_FLOW_CONFIGURATION_MISMATCH"
      print "NIMBLE_CENTRAL RECEIVE_FLOW packets=$receive-acl-packets"
      host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
      address := (hex.decode "98cdac60e0ae").reverse
      print "NIMBLE_CENTRAL READY mode=$(saved ? "resume" : "pair")"
      link := host.connect address --address-type=0
      owner/Owner := saved
          ? (bond-resume.Resume host link saved --local-address=info.address)
          : (security.Pairing host link --local-address=info.address --io-capability=3 --no-require-authentication --bond)
      client = att.Client host link --pairing=owner
      if saved:
        (owner as bond-resume.Resume).run
      else:
        (owner as security.Pairing).run (: unreachable) --candidate=: | candidate/bond.Candidate |
          if candidate.peer.address-type != 0 or candidate.peer.address != address: throw "UNEXPECTED_BOND_PEER"
          store.save #[1] candidate
          print "NIMBLE_CENTRAL SAVED"
      if not owner.paired or not owner.encrypted or owner.authenticated: throw "EXPECTED_ENCRYPTED_JUST_WORKS"
      service := fixture.find-uuid (gatt.services client) #[0xf0, 0xff]
      value := fixture.find-uuid (gatt.characteristics client service) #[0xf1, 0xff]
      retained := client.read value.handle
      before := system.process-stats --gc
      10.repeat:
        if (client.read value.handle) != #[42]: throw "ENCRYPTED_READ_FAILED"
        system.process-stats --gc
      after := system.process-stats --gc
      gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
      if retained != #[42] or gcs < 10: throw "RETAINED_OR_GC_FAILED"
      host.disconnect link
      print "NIMBLE_CENTRAL COMPLETE resumed=$(saved != null) encrypted=true authenticated=false reads=11 retained=true full-gcs=$gcs"
    finally:
      if client: client.close
      if host:
        host.close
        host.wait-closed
      else:
        controller.close
        controller.wait-closed
      store.close
