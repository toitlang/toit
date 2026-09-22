// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-flash
import ble.experimental.bond-storage
import ble.experimental.bond-table
import ble.experimental.bond-registry
import ble.experimental.bond-resume
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.hexdump
import ble.experimental.hci
import ble.experimental.security-owner show Owner
import ble.experimental.smp-identity show Identity
import ble.experimental.service.client as clients
import ble.experimental.service.central-provider as central-provider
import ble.experimental.service.bond-admin-client as admin
import ble.experimental.service.bond-admin-provider as administration
import encoding.hex
import monitor
import system
import system.containers
import .vhci-central-provider as diagnostics

// Uses the existing S3 Board1/NimBLE Board2 fixture bond without modifying it.
// Only the separate live-admin namespace is seeded/deleted. Keys are public
// fixture material; this does not provision a production administrator.
source-store -> bond-storage.Storage:
  return bond-storage.Storage
      bond-flash.FlashRecords "toit.test/nimble-central-resume-v1"
      ByteArray 32: it

main arguments:
  with-timeout --ms=60_000:
    if arguments is Map:
      application arguments["provider"]
    else:
      run

run --receive-acl-packets/int=0:
  source := source-store
  saved/bond.Candidate? := null
  try:
    saved = source.load #[1]
    if not saved: throw "LIVE_ADMIN_FIXTURE_BOND_MISSING"
  finally:
    source.close
  table := bond-table.Table
      bond-flash.FlashRecords "toit.test/bond-admin-live-v3"
      ByteArray 32: it
      --capacity=2
  table.remove 0
  table.remove 1
  registry := bond-registry.Registry table --owner-limit=2
  if (registry.add saved) != 0: throw "LIVE_ADMIN_WRONG_SLOT"
  extra := bond.Candidate (ByteArray 16 --initial=42) saved.local
      Identity (ByteArray 16) #[1, 2, 3, 4, 5, 6] 0
      --no-authenticated
  provider := Provider registry --receive-acl-packets=receive-acl-packets
  provider.install
  child := containers.start containers.current {"provider": Process.current.id}
  administrator := Administrator registry child.gid extra
  administrator.install
  try:
    if child.wait != 0: throw "LIVE_ADMIN_CHILD_FAILED"
    if provider.opens != 2 or provider.radios.size != 2:
      throw "LIVE_ADMIN_MISSING_CONTROLLER_DISCONNECTION"
    encryptions := 0
    provider.radios.do: | radio/Radio |
      with-timeout --ms=3_000: radio.disconnected.get
      if radio.disconnections != 1: throw "LIVE_ADMIN_WRONG_DISCONNECTION_COUNT"
      encryptions += radio.encryptions
    if encryptions != 1: throw "LIVE_ADMIN_REVOKED_KEY_SUBMITTED"
    if table.load 0: throw "LIVE_ADMIN_BOND_NOT_REMOVED"
    if (table.load 1).encode != extra.encode: throw "LIVE_ADMIN_OTHER_SLOT_CHANGED"
  finally:
    critical-do --no-respect-deadline:
      child.close
      administrator.uninstall
      provider.uninstall
      registry.close
  source = source-store
  try:
    if (source.load #[1]).encode != saved.encode: throw "LIVE_ADMIN_SOURCE_BOND_CHANGED"
  finally:
    source.close
  print "LIVE_ADMIN COMPLETE child-exit=0 controller-opens=2 disconnections=2 encryptions=1 source-bond-preserved=true"

application pid/int:
  client := clients.Client --provider-pid=pid
  administrator := AdminClient --provider-pid=pid
  client.open
  administrator.open
  try:
    client.with-connection (hex.decode "98cdac60e0ae").reverse --require-encryption: | connection/clients.Connection |
      state := connection.security
      if not state.encrypted or state.authenticated: throw "LIVE_ADMIN_EXPECTED_ENCRYPTED_JUST_WORKS"
      services := connection.database.discover-services.filter: it.uuid == #[0xf0, 0xff]
      if services.size != 1: throw "LIVE_ADMIN_SERVICE_MISSING"
      values := services[0].characteristics.filter: it.uuid == #[0xf1, 0xff]
      if values.size != 1: throw "LIVE_ADMIN_VALUE_MISSING"
      value := values[0]
      retained := value.read
      if retained != #[42]: throw "LIVE_ADMIN_BAD_VALUE"
      old := administrator.bonds
      if old.size != 1: throw "LIVE_ADMIN_BAD_INVENTORY"
      administrator.add-unrelated
      if (catch: administrator.revoke-bond old[0]) != "BLE_STALE_BOND_INVENTORY":
        throw "LIVE_ADMIN_STALE_ACCEPTED"
      if value.read != #[42] or not connection.security.encrypted:
        throw "LIVE_ADMIN_STALE_REQUEST_DROPPED_LINK"
      print "LIVE_ADMIN STALE rejected=true encrypted-read=42"
      current := administrator.bonds
      if current.size != 2: throw "LIVE_ADMIN_BAD_CURRENT_INVENTORY"
      administrator.revoke-bond current[0]
      error := catch: value.read
      if error != "BLE_BOND_RESUME_CLOSED" and error != "ATT_CLOSED" and
          error != "HCI_LINK_DISCONNECTED" and error != "GATT_DATABASE_CHANGED":
        throw "LIVE_ADMIN_UNEXPECTED_READ_RESULT: $error"
      connection.disconnect
      remaining := administrator.bonds
      if remaining.size != 1 or remaining[0].slot != 1: throw "LIVE_ADMIN_BAD_REMAINING_SLOT"
      system.process-stats --gc
      if retained != #[42]: throw "LIVE_ADMIN_RETAINED_VALUE_CHANGED"
      print "LIVE_ADMIN REVOKED read-error=$error remaining-slot=1 retained=true"
    rejected := catch:
      client.with-connection (hex.decode "98cdac60e0ae").reverse --require-encryption:
        throw "LIVE_ADMIN_REVOKED_CONNECTION_EXPOSED"
    if rejected != "BLE_BOND_NOT_FOUND": throw "LIVE_ADMIN_RECONNECT_RESULT: $rejected"
    print "LIVE_ADMIN RECONNECT rejected=BLE_BOND_NOT_FOUND"
  finally:
    administrator.close
    client.close

/** Wraps every opened controller transport in an HCI hexdump when true. */
trace-hci/bool := false

class Provider extends central-provider.Provider:
  registry_/bond-registry.Registry
  receive-acl-packets_/int
  opens/int := 0
  radios/List ::= []
  constructor .registry_ --receive-acl-packets/int=0:
    receive-acl-packets_ = receive-acl-packets
    super
  receive-acl-packets -> int: return receive-acl-packets_
  create-central-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    if controller.receive-flow-control != (receive-acl-packets_ != 0):
      throw "LIVE_ADMIN_RECEIVE_FLOW_MISMATCH"
    print "LIVE_ADMIN RECEIVE_FLOW packets=$receive-acl-packets_"
    return super controller info receive-limit
  central-session-limit -> int: return 2
  open-transport -> Radio:
    opens++
    radio := Radio (trace-hci ? (hexdump.Hexdump esp32.Esp32Transport) : esp32.Esp32Transport)
    radios.add radio
    return radio
  create-central-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    return registry_.resume host link --local-address=info.address
  run-central-security-owner owner/Owner -> none:
    (owner as bond-resume.Resume).run

class Radio extends diagnostics.Diagnostics:
  disconnections/int := 0
  encryptions/int := 0
  disconnected/monitor.Latch ::= monitor.Latch
  constructor transport: super transport
  receive -> ByteArray:
    packet := super
    if packet.size == 7 and packet[..4] == #[4, 5, 4, 0]:
      disconnections++
      disconnected.set true
    return packet
  send packet/ByteArray -> none:
    if packet.size == 32 and packet[..4] == #[1, 0x19, 0x20, 28]: encryptions++
    super packet

class AdminClient extends admin.Client:
  constructor --provider-pid/int: super --provider-pid=provider-pid
  add-unrelated -> none: invoke_ 1000 null

class Administrator extends administration.Provider:
  registry_/bond-registry.Registry
  gid_/int
  extra_/bond.Candidate
  constructor .registry_ .gid_ .extra_:
    super registry_ --administrator-gid=gid_
  handle index/int arguments/any --gid/int --client/int -> any:
    if index == 1000:
      if gid != gid_: throw "BLE_BOND_ADMIN_DENIED"
      if (registry_.add extra_) != 1: throw "LIVE_ADMIN_UNRELATED_SLOT_FAILED"
      return null
    return super index arguments --gid=gid --client=client
