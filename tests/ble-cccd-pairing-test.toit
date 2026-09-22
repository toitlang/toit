// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.acl
import ble.experimental.attribute-server as attributes
import ble.experimental.bond
import ble.experimental.bond-registry
import ble.experimental.bond-table
import ble.experimental.cccd-storage
import ble.experimental.central
import ble.experimental.connection
import ble.experimental.encryption
import ble.experimental.gatt-server
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.smp-pairing as smp
import ble.experimental.smp-identity show Identity
import expect show *
import monitor
import system
import .ble-bond-table-test as storage
import .ble-fixture as fixture
import .ble-security-test as wire
import .ble-security-identity-test as identities
import .ble-key-reply-test as keys
import .ble-smp-identity-test as identity-fixture

DATABASE-ID ::= #[1, 2, 3]

main:
  with-timeout --ms=10_000:
    [false, true].do: | peripheral/bool |
      [false, true].do: | numeric/bool |
        run "success" --peripheral=peripheral --numeric=numeric
      run "storage-error" --peripheral=peripheral
    run "close"
    run "cancel"
    run "declined"
    run "duplicate"
    run "full"
    run "delayed-identity" --peripheral --numeric
    run "revoke" --peripheral --numeric

class HeldRecords extends storage.MemoryRecords:
  hold/bool := true
  entered/monitor.Latch ::= monitor.Latch
  release/monitor.Latch ::= monitor.Latch
  constructor entries/Map: super entries
  write name/string bytes/ByteArray -> none:
    if hold:
      entered.set true
      release.get
    super name bytes

database -> attributes.Database:
  result := attributes.Database
  result.add-service #[0xf0, 0xff]
  result.add-characteristic #[0xf1, 0xff] --read --notify --value=#[42]
  return result

run mode/string --peripheral/bool=false --numeric/bool=false:
  radio := fixture.FakeTransport
  host := central.Central (hci.Controller radio)
  local := Identity (ByteArray 16 --initial=1) #[6, 5, 4, 3, 2, 1] 0
  peer-id := Identity (ByteArray 16 --initial=2) #[1, 2, 3, 4, 5, 0xc6] 1
  bond-entries := {:}
  configuration-entries := {:}
  backend := HeldRecords bond-entries
  backend.fail-after-write = mode == "storage-error"
  table := bond-table.Table backend (ByteArray 32 --initial=42) --capacity=1
  bank := cccd-storage.Storage (storage.MemoryRecords configuration-entries) (ByteArray 32 --initial=43)
  previous/bond.Candidate? := null
  if mode == "duplicate" or mode == "full":
    previous = bond.Candidate (ByteArray 16 --initial=3) local
        (mode == "duplicate" ? peer-id : local)
        --no-authenticated
    backend.hold = false
    table.add previous
    backend.hold = true
    (bank.session 0 previous --database-id=DATABASE-ID).save #[1, 0]
  previous-configuration := configuration-entries.copy
  registry := bond-registry.Registry table --cccd-storage=bank
  peer := smp.Session --initiator=peripheral --io-capability=(numeric ? 1 : 3)
      --require-authentication=numeric
      --bond=(mode != "declined")
      --distribute-identity=(mode != "declined")
      --request-identity=(mode != "declined")
      --local-address=#[1, 6, 5, 4, 3, 2, 1]
      --peer-address=#[0, 1, 2, 3, 4, 5, 6]
  start := monitor.Latch
  distributed := monitor.Latch
  identity-pending := monitor.Latch
  allow-identity := monitor.Latch
  ended := monitor.Latch
  worker/Task? := null
  serving/Task? := null
  server/gatt-server.Server? := null
  result/any := null
  retained/bond.Candidate? := null
  responder := task::
    if peripheral:
      keys.establish radio
      start.get
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
    radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
    if mode != "declined":
      if peripheral: identities.check-local radio reassembler local
      packets := peer-id.packets identity-fixture.Security
      wire.send-smp radio [packets[0]]
      if mode == "delayed-identity":
        identity-pending.set true
        allow-identity.get
      wire.send-smp radio [packets[1]]
      if not peripheral: identities.check-local radio reassembler local
    distributed.set true
  try:
    link := peripheral
        ? (host.accept #[2, 1, 6])
        : (host.connect #[1, 2, 3, 4, 5, 6] --address-type=1)
    pairing := security.Pairing host link --local-address=local.address
        --io-capability=(numeric ? 1 : 3)
        --require-authentication=numeric
        --identity=local
        --request-identity
    owner := registry.bond host link pairing --local-address=local.address
    store := registry.cccd-store owner --database-id=DATABASE-ID
    expect-null store.load
    expect-throw "BLE_BOND_NOT_READY": store.save #[1, 0]
    server = gatt-server.Server host link database --pairing=owner --cccd-store=store
    serving = task:: catch: server.serve: null
    worker = task::
      try:
        result = catch: owner.run: | number/int |
          identities.confirm-peer peer radio numeric number
      finally:
        critical-do --no-respect-deadline: ended.set true
    // The peripheral's pairing worker must start before the peer's first PDU.
    sleep --ms=1
    start.set true
    if mode == "delayed-identity":
      identity-pending.get
      expect (not owner.encrypted)
      radio.received.add (fixture.att-event #[0x12, 4, 0, 1, 0])
      fixture.att-sent radio #[1, 0x12, 4, 0, 0x0f]
      expect (not backend.entered.has-value)
      allow-identity.set true
    if mode == "declined" or mode == "duplicate" or mode == "full":
      ended.get
      expect-equals (mode == "declined" ? "SMP_BOND_NOT_NEGOTIATED" :
          (mode == "duplicate" ? "BLE_BOND_ALREADY_EXISTS" : "BLE_BOND_TABLE_FULL")) result
      expect (not owner.encrypted and not link.connected)
      expect (not backend.entered.has-value)
      expect-equals previous-configuration.size configuration-entries.size
      previous-configuration.do: | name/string bytes/ByteArray |
        expect-equals bytes configuration-entries[name]
      expect-equals (previous ? 1 : 0) registry.bonds.size
      if previous: expect-equals previous.encode (table.load 0).encode
      expect-throw "BLE_BOND_OWNER_EXPIRED": store.load
      return
    backend.entered.get
    distributed.get
    expect pairing.encrypted
    expect (not owner.encrypted and not owner.authenticated)
    expect (configuration-entries.is-empty)
    // A held bond write does not block the ATT/SMP receive loop. Early CCCD
    // writes get an insufficient-encryption response and never touch storage.
    radio.received.add (fixture.att-event #[0x12, 4, 0, 1, 0])
    fixture.att-sent radio #[1, 0x12, 4, 0, 0x0f]
    expect (configuration-entries.is-empty)
    expect (not server.notify 3)
    if mode == "close": owner.close
    if mode == "cancel": worker.cancel
    backend.release.set true
    ended.get
    if mode == "storage-error" or mode == "close" or mode == "cancel":
      expect (not owner.encrypted and not owner.authenticated and not link.connected)
      expect (configuration-entries.is-empty)
      if mode == "storage-error": expect-equals "STORAGE_FAILED" result
      if mode == "close": expect-equals "BLE_BOND_OWNER_EXPIRED" result
      expect-throw "BLE_BOND_REGISTRY_FAILED": registry.bonds
      expect-throw "BLE_BOND_REGISTRY_FAILED": store.load
      return
    expect-null result
    expect owner.encrypted
    expect-equals numeric owner.authenticated
    expect-equals [0] table.occupied
    retained = table.load 0
    expect-equals peer.key retained.key
    expect-equals peer-id.irk retained.peer.irk
    expect-equals numeric retained.authenticated
    expect-throw "BLE_BOND_PAIRING_INVALID_STATE": owner.run: unreachable
    radio.received.add (fixture.att-event #[0x12, 4, 0, 1, 0])
    fixture.att-sent radio #[0x13]
    system.process-stats --gc
    expect-equals #[1, 1, 4, 0, 1, 0] store.load
    expect (server.notify 3)
    fixture.att-sent radio #[0x1b, 3, 0, 42]
    if mode == "revoke":
      registry.remove 0
      expect (not owner.encrypted and not link.connected)
      expect (configuration-entries.is-empty)
      expect-equals [] table.occupied
      expect-throw "BLE_BOND_OWNER_EXPIRED": store.load
      return
    owner.close
    expect-throw "BLE_BOND_OWNER_EXPIRED": store.save #[1, 0]
  finally:
    backend.release.set true
    if worker: worker.cancel
    if serving: serving.cancel
    if server: server.close
    responder.cancel
    peer.close
    registry.close
    host.close
    host.wait-closed
  // Reconstruct the registry and record wrappers, then use a new real Resume
  // owner and scripted controller encryption. No CCCD rewrite is performed.
  system.process-stats --gc
  resume retained bond-entries configuration-entries

resume candidate/bond.Candidate bond-entries/Map configuration-entries/Map:
  table := bond-table.Table (storage.MemoryRecords bond-entries) (ByteArray 32 --initial=42) --capacity=1
  bank := cccd-storage.Storage (storage.MemoryRecords configuration-entries) (ByteArray 32 --initial=43)
  registry := bond-registry.Registry table --cccd-storage=bank
  radio := fixture.FakeTransport
  host := central.Central (hci.Controller radio)
  server/gatt-server.Server? := null
  serving/Task? := null
  responder := task::
    parameters := connection.create-parameters candidate.peer.address --address-type=candidate.peer.address-type
    fixture.status-reply radio (hci.command-packet 0x200d parameters)
    event := fixture.connection-event.copy
    event[8] = candidate.peer.address-type
    event.replace 9 candidate.peer.address
    radio.received.add event
    fixture.status-reply radio (hci.command-packet 0x2019 (encryption.enable-parameters 0x234 candidate.key))
    radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
  try:
    link := host.connect candidate.peer.address --address-type=candidate.peer.address-type
    pairing := security.Pairing host link --local-address=candidate.local.address
        --io-capability=3
        --no-require-authentication
        --bond
    expect-throw "BLE_BOND_ALREADY_EXISTS": registry.bond host link pairing --local-address=candidate.local.address
    owner := registry.resume host link --local-address=candidate.local.address
    store := registry.cccd-store owner --database-id=DATABASE-ID
    server = gatt-server.Server host link database --pairing=owner --cccd-store=store
    serving = task:: catch: server.serve: null
    expect (not server.notify 3)
    owner.run
    expect-equals candidate.authenticated owner.authenticated
    radio.received.add (fixture.att-event #[0x0a, 4, 0])
    fixture.att-sent radio #[0x0b, 1, 0]
    expect (server.notify 3)
    fixture.att-sent radio #[0x1b, 3, 0, 42]
    registry.remove 0
    expect (not owner.encrypted and not link.connected)
    expect (configuration-entries.is-empty)
    expect-throw "BLE_BOND_OWNER_EXPIRED": store.load
  finally:
    if serving: serving.cancel
    if server: server.close
    responder.cancel
    registry.close
    host.close
    host.wait-closed
