// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-flash
import ble.experimental.bond-info show BondInfo
import ble.experimental.bond-registry
import ble.experimental.bond-table
import ble.experimental.smp-identity show Identity
import ble.experimental.service.bond-admin-client as clients
import ble.experimental.service.bond-admin-provider as providers
import monitor
import system
import system.containers

// Public fixture keys and a dedicated namespace. This is not provisioning and
// never opens a radio or modifies another fixture's stored bonds.
NAMESPACE ::= "toit.test/bond-admin-v3"

candidate peer/int -> bond.Candidate:
  local := Identity (ByteArray 16) #[1, 2, 3, 4, 5, 6] 0
  remote := Identity (ByteArray 16) #[peer, 2, 3, 4, 5, 6] 0
  return bond.Candidate (ByteArray 16 --initial=peer) local remote --authenticated

open-table -> bond-table.Table:
  return bond-table.Table (bond-flash.FlashRecords NAMESPACE) (ByteArray 32: it) --capacity=2

main arguments:
  with-timeout --ms=30_000:
    if arguments is Map:
      application arguments
    else:
      run

run:
  table := open-table
  restored := table.load 1
  if restored:
    if restored.encode != (candidate 2).encode or (table.load 0) != null:
      throw "BOND_ADMIN_RESTART_STATE_MISMATCH"
  print "BOND_ADMIN RESTORED previous=$(restored != null)"
  table.remove 0
  table.remove 1
  registry := bond-registry.Registry table
  registry.add (candidate 1)
  registry.add (candidate 2)
  administrator := containers.start containers.current {"admin": true, "provider": Process.current.id}
  outsider := containers.start containers.current {"admin": false, "provider": Process.current.id}
  provider := Provider registry administrator.gid
  provider.install
  try:
    if outsider.wait != 0: throw "BOND_ADMIN_OUTSIDER_FAILED"
    provider.start.set true
    provider.replace-ready.get
    registry.remove 0
    if (registry.add (candidate 3)) != 0: throw "BOND_ADMIN_SLOT_NOT_REUSED"
    provider.replaced.set true
    if administrator.wait != 0: throw "BOND_ADMIN_APPLICATION_FAILED"
    remaining := registry.bonds
    if remaining.size != 1 or (remaining[0] as BondInfo).slot != 1:
      throw "BOND_ADMIN_WRONG_REMAINING_SLOT"
  finally:
    critical-do --no-respect-deadline:
      provider.start.set true
      provider.replaced.set true
      administrator.close
      outsider.close
      provider.uninstall
      registry.close
  // Reopen through protected storage after both clients and the registry ended.
  reopened := open-table
  try:
    surviving := reopened.load 1
    if (reopened.load 0) != null or not surviving or surviving.encode != (candidate 2).encode:
      throw "BOND_ADMIN_REOPEN_MISMATCH"
  finally:
    reopened.close
  print "BOND_ADMIN COMPLETE admin-exit=0 outsider-exit=0 remaining-slot=1 reopened=true"

application arguments/Map:
  client := Client --provider-pid=arguments["provider"]
  client.open --timeout=(Duration --s=5)
  try:
    if not arguments["admin"]:
      if (catch: client.bonds) != "BLE_BOND_ADMIN_DENIED": throw "BOND_ADMIN_INVENTORY_NOT_DENIED"
      if (catch: client.revoke 0) != "BLE_BOND_ADMIN_DENIED": throw "BOND_ADMIN_REVOKE_NOT_DENIED"
      if (catch: client.raw 3 [0, (ByteArray 16)]) != "BLE_BOND_ADMIN_DENIED":
        throw "BOND_ADMIN_CONDITIONAL_NOT_DENIED"
      print "BOND_ADMIN OUTSIDER denied=3"
      return
    client.raw 1001 null
    inventory := client.bonds
    if inventory.size != 2: throw "BOND_ADMIN_BAD_INVENTORY"
    first/BondInfo := inventory[0]
    if first.slot != 0 or first.peer-address != #[1, 2, 3, 4, 5, 6]:
      throw "BOND_ADMIN_BAD_FIRST_PEER"
    client.raw 1000 null
    if (catch: client.revoke-bond first) != "BLE_STALE_BOND_INVENTORY":
      throw "BOND_ADMIN_STALE_SELECTION_ACCEPTED"
    current := client.bonds
    replacement/BondInfo := current[0]
    if current.size != 2 or replacement.slot != 0 or replacement.peer-address != #[3, 2, 3, 4, 5, 6]:
      throw "BOND_ADMIN_REPLACEMENT_LOST"
    client.revoke-bond replacement
    if (catch: client.revoke-bond current[1]) != "BLE_STALE_BOND_INVENTORY":
      throw "BOND_ADMIN_OTHER_STALE_SELECTION_ACCEPTED"
    remaining := client.bonds
    if remaining.size != 1: throw "BOND_ADMIN_BAD_FINAL_INVENTORY"
    saved/BondInfo := remaining[0]
    system.process-stats --gc
    if saved.slot != 1 or saved.peer-address != #[2, 2, 3, 4, 5, 6] or not saved.authenticated:
      throw "BOND_ADMIN_RETAINED_METADATA_CHANGED"
    print "BOND_ADMIN ADMIN stale-rejected=2 replacement-preserved=true retained=true"
  finally:
    client.close

class Client extends clients.Client:
  constructor --provider-pid/int:
    super --provider-pid=provider-pid
  raw index/int arguments/any: return invoke_ index arguments

// Fixture-only ordering barriers. Production administration has no such methods.
class Provider extends providers.Provider:
  start/monitor.Latch ::= monitor.Latch
  replace-ready/monitor.Latch ::= monitor.Latch
  replaced/monitor.Latch ::= monitor.Latch
  administrator_/int
  constructor registry/bond-registry.Registry .administrator_:
    super registry --administrator-gid=administrator_
  handle index/int arguments/any --gid/int --client/int -> any:
    if index == 1000 or index == 1001:
      if gid != administrator_: throw "BLE_BOND_ADMIN_DENIED"
      if index == 1001:
        start.get
      else:
        replace-ready.set true
        replaced.get
      return null
    return super index arguments --gid=gid --client=client
