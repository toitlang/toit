// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.attribute-server as attributes
import ble.experimental.bond
import ble.experimental.bond-resume
import ble.experimental.bond-table
import ble.experimental.bond-registry
import ble.experimental.cccd-storage
import ble.experimental.central
import ble.experimental.connection
import ble.experimental.encryption
import ble.experimental.hci
import ble.experimental.smp-identity show Identity
import expect show *
import io
import monitor
import system
import .ble-fixture as fixture
import .ble-multilink-test as wire
import .ble-peripheral-test as peripheral
import .ble-key-reply-test as keys
import .ble-bond-table-test as storage

main:
  with-timeout --ms=10_000:
    close-failure
    close-failure --cancel-delete
    run --no-managed
    run --managed
    run --managed --configuration
    run --managed --deletion-fails
    run --managed --cancel-delete

// Isolates registry cleanup from controller cleanup: the injected host accepts
// synthetic central links and throws at the abort boundary for the first owner.
close-failure --cancel-delete/bool=false:
  identity := Identity (ByteArray 16) #[6, 5, 4, 3, 2, 1] 0
  candidate := bond.Candidate keys.KEY identity identity --authenticated
  records := storage.MemoryRecords {:}
  table := bond-table.Table records (ByteArray 32 --initial=42) --capacity=1
  registry := bond-registry.Registry table --owner-limit=2
  registry.add candidate
  host := FailingAbortHost --hold=cancel-delete
  a := central.Link (connection.Completion 0 1 0 identity.address 24 0 400) --acl-count=1
  b := central.Link (connection.Completion 0 2 0 identity.address 24 0 400) --acl-count=1
  deleting/Task? := null
  try:
    first := registry.resume host a --local-address=identity.address
    second := registry.resume host b --local-address=identity.address
    if cancel-delete:
      ended := monitor.Latch
      deleting = task::
        try:
          catch: registry.remove 0
        finally:
          critical-do --no-respect-deadline: ended.set true
      host.entered.get
      deleting.cancel
      host.release.set true
      ended.get
    else:
      expect-throw "INJECTED_ABORT_FAILURE": registry.remove 0
    expect-equals [1, 2] host.aborted
    expect-throw "BLE_BOND_RESUME_INVALID_STATE": first.run
    expect-throw "BLE_BOND_RESUME_INVALID_STATE": second.run
    // Cleanup uncertainty must not delete storage or permit fresh admission.
    expect-equals [0] table.occupied
    expect-throw "BLE_BOND_REGISTRY_FAILED": registry.resume host a --local-address=identity.address
    registry.close
    expect-equals [1, 2] host.aborted
    expect-equals 1 records.closes
  finally:
    host.release.set true
    if deleting: deleting.cancel
    registry.close
    host.close
    host.wait-closed

class FailingAbortHost extends central.Central:
  aborted/List ::= []
  hold_/bool
  entered/monitor.Latch ::= monitor.Latch
  release/monitor.Latch ::= monitor.Latch

  constructor --hold/bool:
    hold_ = hold
    super (hci.Controller fixture.FakeTransport)

  owns-link link/central.Link -> bool: return true

  abort link/central.Link --error="HCI_LINK_CLOSED" -> none:
    aborted.add link.info.handle
    if link.info.handle == 1:
      if hold_:
        entered.set true
        release.get
      throw "INJECTED_ABORT_FAILURE"

// Optional test adapter for exercising the same live-link assertions through
// an administrative RPC instead of an in-process registry call.
abstract class Revoker:
  abstract remove registry/bond-registry.Registry -> none
  abstract cancel -> none

run --managed/bool --deletion-fails/bool=false --cancel-delete/bool=false
    --revoker/Revoker?=null --configuration/bool=false:
  failed := deletion-fails or cancel-delete
  local := Identity (ByteArray 16) #[6, 5, 4, 3, 2, 1] 0
  first := bond.Candidate keys.KEY local (Identity (ByteArray 16) (wire.address 1) 0) --authenticated
  second := bond.Candidate (ByteArray 16 --initial=42) local (Identity (ByteArray 16) (wire.address 2) 0)
      --authenticated
  records := HeldRecords
  table := bond-table.Table records (ByteArray 32 --initial=42) --capacity=2
  configuration-bank := configuration
      ? (cccd-storage.Storage (storage.MemoryRecords {:}) (ByteArray 32 --initial=43))
      : null
  registry := managed ? (bond-registry.Registry table --owner-limit=2 --cccd-storage=configuration-bank) : null
  if registry:
    expect-equals 0 (registry.add first)
    expect-equals 1 (registry.add second)
  else:
    table.add first
    table.add second
  radio := fixture.FakeTransport
  host := central.Central (hci.Controller radio) --link-limit=2 --acl-count=2
  ready := monitor.Latch
  revoked := monitor.Latch
  finish := monitor.Latch
  b-key := monitor.Latch
  replacement-key := monitor.Latch
  replacement-ready := monitor.Latch
  registry-ended := monitor.Latch
  client/att.Client? := null
  deleting/Task? := null
  responder := task::
    establish radio 1 0x234
    establish radio 2 0x235
    ready.get
    reply-key radio 0x234 first.key
    radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
    reply-key radio 0x235 second.key
    radio.received.add #[4, 8, 4, 0, 0x35, 2, 1]
    revoked.get
    fixture.status-reply radio #[1, 6, 4, 3, 0x34, 2, 0x13]
    // A is quarantined but still physically connected. Its late request must
    // not get a key reply or interfere with B's independent key lifetime.
    radio.received.add keys.request
    reply-key radio 0x235 second.key
    b-key.set true
    expect-equals #[2, 0x35, 2, 7, 0, 3, 0, 4, 0, 0x0a, 3, 0] radio.sent.take
    wire.completed radio 0x235
    wire.incoming radio 0x235 #[2, 0, 4, 0, 0x0b, 42] --start
    finish.get
    wire.ended radio 0x234
    establish radio 3 0x234
    // The reused handle has no installed bond and must not inherit A's key.
    radio.received.add keys.request
    keys.negative radio
    replacement-key.set true
    if managed and not failed:
      replacement-ready.get
      reply-key radio 0x234 first.key
      radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
      disconnected := {}
      2.repeat:
        command := radio.sent.take
        expect-equals 7 command.size
        expect-equals #[1, 6, 4, 3] command[..4]
        expect-equals 0x13 command[6]
        handle := io.LITTLE-ENDIAN.uint16 command 4
        expect (handle == 0x234 or handle == 0x235)
        expect (not (disconnected.contains handle))
        disconnected.add handle
        radio.received.add #[4, 15, 4, 0, 1, 6, 4]
        wire.ended radio handle
      registry-ended.set true
  try:
    a := host.accept #[2, 1, 6]
    owner-a := managed
        ? (registry.resume host a --local-address=local.address --require-authentication)
        : (bond-resume.Resume host a first --local-address=local.address --require-authentication)
    if managed:
      // A spare registry slot must not permit a second owner for this link.
      expect-throw "BLE_BOND_OWNER_EXISTS": registry.resume host a --local-address=local.address
    b := host.accept #[2, 1, 6]
    owner-b := managed
        ? (registry.resume host b --local-address=local.address --require-authentication)
        : (bond-resume.Resume host b second --local-address=local.address --require-authentication)
    ready.set true
    owner-a.run
    owner-b.run
    if managed:
      expect-throw "BLE_BOND_OWNER_LIMIT": registry.resume host b --local-address=local.address
      expect-throw "INVALID_ARGUMENT": registry.remove 2
      expect-throw "BLE_BOND_TABLE_FULL": registry.add first
    client = att.Client host b --pairing=owner-b
    database := attributes.Database
    database.add-service #[0xf0, 0xff]
    database.add-characteristic #[0xf1, 0xff] --read --notify=configuration --authenticated --value=#[7]
    config-a := configuration ? (registry.cccd-store owner-a --database-id=#[1]) : null
    config-b := configuration ? (registry.cccd-store owner-b --database-id=#[1]) : null
    access-a := database.session --security=owner-a --cccd-store=config-a
    access-b := database.session --security=owner-b --cccd-store=config-b
    expect-equals #[0x0b, 7] (access-a.request #[0x0a, 3, 0])
    expect-equals #[0x0b, 7] (access-b.request #[0x0a, 3, 0])
    if configuration:
      expect-equals #[0x13] (access-a.request #[0x12, 4, 0, 1, 0])
      expect-equals #[0x13] (access-b.request #[0x12, 4, 0, 1, 0])
      expect-equals #[0x1b, 3, 0, 7] (access-a.notification 3)
      expect-equals #[0x1b, 3, 0, 7] (access-b.notification 3)
    // Trusted-provider policy: withdraw live access before deleting storage.
    if managed:
      records.hold = true
      records.ignore-delete = deletion-fails
      removed := monitor.Latch
      deletion-ended := monitor.Latch
      deleting = task::
        try:
          removed.set (catch:
            if revoker: revoker.remove registry
            else: registry.remove 0)
        finally:
          critical-do --no-respect-deadline: deletion-ended.set true
      records.entered.get
      // The lookup/registration boundary cannot race suspended storage IO.
      expect-throw "BLE_BOND_ADMISSION_PAUSED": registry.resume host b --local-address=local.address
      expect (not owner-a.authenticated and owner-b.authenticated)
      expect-equals #[1, 0x0a, 3, 0, 5] (access-a.request #[0x0a, 3, 0])
      if cancel-delete:
        if revoker: revoker.cancel
        deleting.cancel
        deletion-ended.get
      else:
        records.release.set true
        expect-equals (deletion-fails ? "BLE_BOND_DELETE_NOT_VERIFIED" : null) removed.get
      if failed:
        expect-throw "BLE_BOND_REGISTRY_FAILED": registry.resume host b --local-address=local.address
        expect-throw "BLE_BOND_REGISTRY_FAILED": registry.remove 0
        expect-throw "BLE_BOND_REGISTRY_FAILED": registry.add first
    else:
      owner-a.close
      owner-a.close
      table.remove 0
    expect-equals (failed ? [0, 1] : [1]) table.occupied
    expect (not owner-a.paired and not owner-a.encrypted and not owner-a.authenticated)
    expect (not a.has-ended)
    system.process-stats --gc
    expect-equals #[1, 0x0a, 3, 0, 5] (access-a.request #[0x0a, 3, 0])
    expect-equals #[0x0b, 7] (access-b.request #[0x0a, 3, 0])
    if configuration:
      expect-null (access-a.notification 3)
      expect-equals #[0x1b, 3, 0, 7] (access-b.notification 3)
      expect-throw "BLE_BOND_OWNER_EXPIRED": config-a.load
    revoked.set true
    b-key.get
    expect-equals #[42] (client.read 3)
    expect (owner-b.authenticated and b.connected and not radio.closed)
    finish.set true
    a.wait-disconnected
    replacement := host.accept #[2, 1, 6]
    replacement-key.get
    if managed:
      expect-throw (failed ? "BLE_BOND_REGISTRY_FAILED" : "BLE_BOND_NOT_FOUND"):
        registry.resume host replacement --local-address=local.address
    expect (replacement.connected and b.connected and owner-b.authenticated)
    expect-equals second.encode (table.load 1).encode
    expect-throw "BLE_BOND_RESUME_INVALID_STATE": owner-a.run
    if managed and not failed:
      third := bond.Candidate first.key local (Identity (ByteArray 16) (wire.address 3) 0)
          --authenticated
      expect-equals 0 (registry.add third)
      owner-c := registry.resume host replacement --local-address=local.address --require-authentication
      // A's released tracking slot now belongs to C. Repeated old-owner cleanup
      // must not remove C from tracking or revoke its newly installed key.
      owner-a.close
      owner-a.close
      expect-throw "BLE_BOND_OWNER_LIMIT": registry.resume host replacement --local-address=local.address
      replacement-ready.set true
      owner-c.run
      expect (owner-c.authenticated and owner-b.authenticated)
      if configuration:
        fresh := database.session --security=owner-c
            --cccd-store=(registry.cccd-store owner-c --database-id=#[1])
        try:
          expect-equals #[0x0b, 0, 0] (fresh.request #[0x0a, 4, 0])
          expect-null (fresh.notification 3)
          expect-equals #[0x1b, 3, 0, 7] (access-b.notification 3)
        finally:
          fresh.close
      registry.close
      registry.close
      expect (not owner-c.authenticated and not owner-b.authenticated)
      expect (not replacement.connected and not b.connected)
      expect (records.closed and records.closes == 1)
      expect-throw "BLE_BOND_REGISTRY_CLOSED": registry.add first
      expect-throw "BLE_BOND_REGISTRY_CLOSED": registry.remove 0
      expect-throw "BLE_BOND_REGISTRY_CLOSED": registry.resume host replacement --local-address=local.address
      registry-ended.get
  finally:
    records.release.set true
    if deleting: deleting.cancel
    responder.cancel
    if client: client.close
    host.close
    host.wait-closed
    if registry: registry.close
    else: table.close

class HeldRecords extends storage.MemoryRecords:
  hold/bool := false
  entered/monitor.Latch ::= monitor.Latch
  release/monitor.Latch ::= monitor.Latch

  constructor: super {:}

  remove name/string -> none:
    if hold:
      entered.set true
      release.get
    super name

establish radio/fixture.FakeTransport peer/int handle/int:
  peripheral.setup radio
  event := wire.connected peer handle
  event[7] = 1
  event[8] = 0
  radio.received.add event
  peripheral.reply radio 0x200a #[0]

reply-key radio/fixture.FakeTransport handle/int key/ByteArray:
  request := keys.request
  io.LITTLE-ENDIAN.put-uint16 request 4 handle
  radio.received.add request
  returned := ByteArray 2
  io.LITTLE-ENDIAN.put-uint16 returned 0 handle
  fixture.reply radio (hci.command-packet 0x201a (encryption.reply-parameters handle key)) returned
