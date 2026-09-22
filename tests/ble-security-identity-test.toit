// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-table
import ble.experimental.acl
import ble.experimental.att
import ble.experimental.central
import ble.experimental.encryption
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.smp-pairing as smp
import ble.experimental.smp-identity as identity
import expect show *
import monitor
import system
import .ble-fixture as fixture
import .ble-security-test as wire
import .ble-key-reply-test as keys
import .ble-smp-identity-test as identity-fixture
import .ble-bond-table-test as storage

main:
  with-timeout --ms=5_000:
    ["success", "partial", "unencrypted", "declined", "missing-identity"].do: run it
    ["storage-error", "table-full"].do: | mode/string |
      [false, true].do: | peripheral/bool |
        [false, true].do: | numeric/bool |
          run mode --peripheral=peripheral --numeric=numeric
    run "success" --peripheral
    run "success" --numeric
    run "success" --numeric --peripheral

run mode/string --peripheral/bool=false --numeric/bool=false:
  radio := fixture.FakeTransport
  host := central.Central (hci.Controller radio)
  local := identity.Identity (ByteArray 16 --initial=1) #[6, 5, 4, 3, 2, 1] 0
  peer-id := identity.Identity (ByteArray 16 --initial=2) #[1, 2, 3, 4, 5, 0xc6] 1
  backend := storage.MemoryRecords {:}
  table := bond-table.Table backend (ByteArray 32 --initial=42) --capacity=1
  previous := bond.Candidate (ByteArray 16 --initial=3) local peer-id --no-authenticated
  if mode == "table-full": table.add previous
  backend.fail-after-write = mode == "storage-error"
  peer := smp.Session --initiator=peripheral --io-capability=(numeric ? 1 : 3) --require-authentication=numeric
      --bond=(mode != "declined")
      --distribute-identity=(mode != "declined" and mode != "missing-identity")
      --request-identity=(mode != "declined")
      --local-address=#[1, 6, 5, 4, 3, 2, 1]
      --peer-address=#[0, 1, 2, 3, 4, 5, 6]
  retained/bond.Candidate? := null
  candidate-calls := 0
  partial := monitor.Latch
  ended := monitor.Latch
  responder := task::
    try:
      if peripheral:
        keys.establish radio
        wire.send-smp radio peer.start
      else:
        fixture.status-reply radio fixture.create-command
        radio.received.add fixture.connection-event
      reassembler := acl.Reassembler 0x234 --limit=65
      while not peer.verified:
        wire.send-smp radio (peer.receive (wire.take-smp radio reassembler))
      if peripheral:
        radio.received.add keys.request
        fixture.reply radio (hci.command-packet 0x201a (encryption.reply-parameters 0x234 peer.key)) #[0x34, 2]
      else:
        fixture.status-reply radio (hci.command-packet 0x2019 (encryption.enable-parameters 0x234 peer.key))
      if mode != "unencrypted": radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
      if mode == "declined" or mode == "missing-identity":
        if mode == "missing-identity": check-local radio reassembler local
        while not radio.closed: sleep --ms=1
      else:
        if peripheral: check-local radio reassembler local
        packets := peer-id.packets identity-fixture.Security
        // Queue distribution directly after the encryption event, before the
        // application pairing task necessarily resumes from its encryption wait.
        wire.send-smp radio [packets[0]]
        if mode == "success" or mode == "storage-error" or mode == "table-full":
          wire.send-smp radio [packets[1]]
          if not peripheral: check-local radio reassembler local
          if mode == "success":
            fixture.gatt-reply radio #[0x0a, 1, 0] #[0x0b, 42]
          else:
            while not radio.closed: sleep --ms=1
        else:
          partial.set true
          while not radio.closed: sleep --ms=1
    finally:
      critical-do --no-respect-deadline: ended.set true
  client/att.Client? := null
  worker/Task? := null
  result := monitor.Latch
  try:
    link := peripheral
        ? (host.accept #[2, 1, 6])
        : (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1)
    pairing := security.Pairing host link --local-address=#[6, 5, 4, 3, 2, 1]
        --io-capability=(numeric ? 1 : 3)
        --require-authentication=numeric
        --identity=local
        --request-identity
    client = att.Client host link --pairing=pairing
    expect-throw "SMP_IDENTITY_NOT_READY": pairing.peer-identity
    worker = task::
      error := catch:
        pairing.run (: | number/int | confirm-peer peer radio numeric number) --candidate=: | candidate/bond.Candidate |
          candidate-calls++
          expect-equals peer.key candidate.key
          expect-equals local.address candidate.local.address
          expect-equals peer-id.irk candidate.peer.irk
          expect-equals numeric candidate.authenticated
          retained = candidate
          system.process-stats --gc
          sleep --ms=1
          table.add candidate
      result.set error
    if mode == "success":
      expect-null result.get
      expect-equals 1 candidate-calls
      expect-equals peer-id.irk pairing.peer-identity.irk
      system.process-stats --gc
      expect-equals peer-id.address pairing.peer-identity.address
      expect pairing.encrypted
      expect-equals #[42] (client.read 1)
    else if mode == "declined" or mode == "missing-identity":
      expected := mode == "declined" ? "SMP_BOND_NOT_NEGOTIATED" : "SMP_BOND_IDENTITY_REQUIRED"
      expect-equals expected result.get
      expect (not pairing.encrypted)
      expect radio.closed
    else if mode == "storage-error" or mode == "table-full":
      expect-equals (mode == "storage-error" ? "STORAGE_FAILED" : "BLE_BOND_TABLE_FULL") result.get
      expect-equals 1 candidate-calls
      expect (not pairing.encrypted)
      expect radio.closed
    else if mode == "partial":
      partial.get
      // No candidate identity is visible after only Identity Information.
      expect-throw "SMP_IDENTITY_NOT_READY": pairing.peer-identity
      worker.cancel
      while not radio.closed: sleep --ms=1
      expect (not pairing.encrypted)
    else if mode == "timeout":
      expect-equals "SMP_TIMEOUT" result.get
      expect (not pairing.encrypted)
      expect-throw "SMP_IDENTITY_NOT_READY": pairing.peer-identity
    else:
      expect ((result.get) != null)
      expect (not pairing.encrypted)
    if mode != "success" and mode != "storage-error" and mode != "table-full":
      expect-equals 0 candidate-calls
      expect-null retained
    client.close
    ended.get
    if retained:
      // An explicitly retained owned candidate survives owner and link cleanup.
      system.process-stats --gc
      expect-equals peer.key retained.key
      expect-equals peer-id.address retained.peer.address
      expect-equals [0] table.occupied
      expected := mode == "table-full" ? previous : retained
      expect-equals expected.encode (table.load 0).encode
      // An ambiguous write can leave a candidate, but must not grant live access.
      table.remove 0
      expect-equals [] table.occupied
    else:
      expect-equals [] table.occupied
  finally:
    if worker: worker.cancel
    if client: client.close
    responder.cancel
    peer.close
    host.close
    host.wait-closed
    table.close

check-local radio/fixture.FakeTransport reassembler/acl.Reassembler local/identity.Identity:
  receiver := identity.Receiver identity-fixture.Security
  receiver.receive (wire.take-smp radio reassembler)
  receiver.receive (wire.take-smp radio reassembler)
  expect-equals local.irk receiver.identity.irk
  expect-equals local.address receiver.identity.address

confirm-peer peer/smp.Session radio/fixture.FakeTransport numeric/bool number/int -> bool:
  expect numeric
  expect-equals peer.comparison-number number
  wire.send-smp radio (peer.approve true)
  return true
