// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.att
import ble.experimental.attribute-server as attributes
import ble.experimental.bond
import ble.experimental.bond-flash
import ble.experimental.bond-storage
import ble.experimental.bond-resume
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.gatt-server as gatt
import ble.experimental.gatt as discovery
import ble.experimental.hci
import ble.experimental.privacy
import ble.experimental.scanning
import ble.experimental.security
import ble.experimental.security-owner show Owner
import ble.experimental.smp-identity
import crypto
import encoding.hex
import monitor
import system
import .hci-echo as fixture

// Public fixture storage key and explicit phase; never silently pair on resume.
run --central/bool --resume/bool --peer-address/ByteArray --storage-path/string --private/bool=false:
  with-timeout --ms=90_000:
    store := bond-storage.Storage (bond-flash.FlashRecords storage-path) (ByteArray 32: it)
    controller := hci.Controller (esp32.Esp32Transport)
    host/Host? := null
    try:
      saved := store.load #[1]
      if (saved != null) != resume: throw "AUTH_PERSIST_WRONG_STORAGE_PHASE"
      if saved and not saved.authenticated: throw "AUTH_PERSIST_UNAUTHENTICATED_BOND"
      if saved and (saved.peer.address != peer-address or saved.peer.address-type != 0):
        throw "AUTH_PERSIST_WRONG_SAVED_PEER"
      if saved and private and (not saved.local.has-resolving-key or not saved.peer.has-resolving-key):
        throw "AUTH_PERSIST_MISSING_IRK"
      original := saved and saved.encode
      info := hci.initialize controller --receive-acl-packets=4
      if not controller.receive-flow-control: throw "AUTH_PERSIST_FLOW_DISABLED"
      host = Host controller info saved
      print "AUTH_PERSIST READY central=$central resume=$resume receive-credits=4"
      local-random := private and resume ? (privacy.generate saved.local.irk) : null
      target := peer-address
      target-type := 0
      if central and local-random:
        with-timeout --ms=10_000:
          scanning.scan controller --active --local-random-address=local-random: | report |
            if report.address-type != 1 or not (report.has-service #[0xf0, 0xff]):
              continue.scan true
            if not (privacy.resolves saved.peer.irk report.address report.address-type):
              continue.scan true
            target = report.address.copy
            target-type = 1
            false
      link := central
          ? (host.connect target --address-type=target-type --local-random-address=local-random)
          : (host.accept #[2, 1, 6, 3, 3, 0xf0, 0xff] --timeout=(Duration --s=60) --local-random-address=local-random)
      if local-random:
        if not (privacy.resolves saved.peer.irk link.info.address link.info.address-type):
          throw "AUTH_PERSIST_UNRESOLVED_PEER"
        print "AUTH_PERSIST PRIVATE local=$(hex.encode local-random.reverse) peer=$(hex.encode link.info.address.reverse) resolved=true"
      else if link.info.address != peer-address or link.info.address-type != 0:
        throw "AUTH_PERSIST_WRONG_PEER"
      identity := private and not resume
          ? (smp-identity.Identity (crypto.random --size=16) info.address 0)
          : null
      owner/Owner := saved ? host.owner : (security.Pairing host link --local-address=info.address
          --io-capability=1
          --require-authentication
          --identity=identity
          --request-identity=private
          --bond)
      if central:
        client := att.Client host link --pairing=owner
        try:
          secure owner store info.address peer-address --resume=resume --private=private
          service := fixture.find-uuid (discovery.services client) #[0xf0, 0xff]
          characteristic := fixture.find-uuid (discovery.characteristics client service) #[0xf1, 0xff]
          retained := client.read characteristic.handle
          before := system.process-stats --gc
          10.repeat:
            if (client.read characteristic.handle) != #[43]: throw "AUTH_PERSIST_BAD_READ"
            system.process-stats --gc
          after := system.process-stats --gc
          gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
          if retained != #[43] or gcs < 10: throw "AUTH_PERSIST_RETAINED_OR_GC"
          host.disconnect link
          print "AUTH_PERSIST READS count=11 retained=true full-gcs=$gcs"
        finally:
          client.close
          client.wait-closed
      else:
        database := attributes.Database.with-defaults --name="Toit auth persist"
        database.add-service #[0xf0, 0xff]
        handle := database.add-characteristic #[0xf1, 0xff] --read --authenticated --value=#[43]
        if handle != 12: throw "AUTH_PERSIST_WRONG_HANDLE"
        server := gatt.Server host link database --pairing=owner
        ended := monitor.Latch
        worker := task:: ended.set (catch: server.serve: unreachable)
        try:
          secure owner store info.address peer-address --resume=resume --private=private
          failure := ended.get
          if failure: throw failure
        finally:
          worker.cancel
          server.close
      stored := store.load #[1]
      if not stored or not stored.authenticated: throw "AUTH_PERSIST_STORAGE_MISSING"
      if private and (not stored.local.has-resolving-key or not stored.peer.has-resolving-key):
        throw "AUTH_PERSIST_IRK_NOT_STORED"
      if resume and stored.encode != original: throw "AUTH_PERSIST_BOND_CHANGED"
      print "AUTH_PERSIST COMPLETE central=$central resumed=$resume authenticated=true stored=true private=$private"
    finally:
      if host:
        host.close
        host.wait-closed
      else:
        controller.close
        controller.wait-closed
      store.close

secure owner/Owner store/bond-storage.Storage local/ByteArray peer/ByteArray --resume/bool --private/bool=false:
  if resume:
    (owner as bond-resume.Resume).run
  else:
    (owner as security.Pairing).run
        (: | number/int |
          print "AUTH_PERSIST NUMERIC value=$number fixture-approval=true"
          true)
        --candidate=: | candidate/bond.Candidate |
          if not candidate.authenticated or candidate.local.address != local or
              candidate.peer.address != peer or candidate.local.address-type != 0 or
              candidate.peer.address-type != 0:
            throw "AUTH_PERSIST_BAD_CANDIDATE"
          if private and (not candidate.local.has-resolving-key or not candidate.peer.has-resolving-key):
            throw "AUTH_PERSIST_IRK_NOT_NEGOTIATED"
          store.save #[1] candidate
          print "AUTH_PERSIST SAVED authenticated=true"
  if not owner.encrypted or not owner.authenticated: throw "AUTH_PERSIST_SECURITY"

class Host extends central.Central:
  saved_/bond.Candidate?
  local_/ByteArray
  owner/bond-resume.Resume? := null
  constructor controller/hci.Controller info/hci.Capabilities .saved_:
    local_ = info.address.copy
    super controller --acl-length=info.acl-length --acl-count=info.acl-count
  on-connected link/central.Link -> none:
    if saved_:
      owner = bond-resume.Resume this link saved_
          --local-address=(link.local-random-address or local_)
          --require-authentication
