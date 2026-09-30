// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import system.services
import ..bond-registry show Registry
import ..bond-info show BondInfo
import .bond-admin-api as api

/**
The optional bond administration service.

Trusted provider code installs a $Provider over its bond $Registry so that
  one administrator container group can list bonds as $BondInfo rows and
  revoke them through `ble.experimental.service.bond-admin-client`. It is
  separate from the BLE service that applications use and shares no
  controller with it.
*/

/**
Exposes bond inventory and revocation to one explicitly selected container group.

Borrows the registry; trusted provider code retains ownership and closes it
  after uninstalling this service. No caller is authorized by default. Pass the
  runtime group ID returned by starting a trusted administrator container; do
  not take this value from an untrusted RPC argument or persist it across boots.
  The grant covers processes in that container group. A restarted container
  receives a new group ID and needs a newly configured service instance.

This service is optional and separate from the ordinary BLE selector. It neither
  starts a controller nor exports, adds or replaces keys. Storage durability and
  live-owner coverage are those of the supplied registry and its backend.
*/
class Provider extends services.ServiceProvider implements services.ServiceHandler:
  registry_/Registry
  administrator-gid_/int?

  constructor .registry_ --administrator-gid/int?=null:
    if administrator-gid != null and not 0 <= administrator-gid <= 0x7fff_ffff:
      throw "INVALID_ARGUMENT"
    administrator-gid_ = administrator-gid
    super "toit.io/experimental/ble-bond-admin" --major=0 --minor=3
    provides api.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    // The service runtime supplies gid from the message sender. Authorization
    // precedes argument inspection and any registry or storage operation.
    if administrator-gid_ == null or gid != administrator-gid_:
      throw "BLE_BOND_ADMIN_DENIED"
    if index == api.BONDS or index == api.BONDS-WITH-REVISION:
      if arguments != null: throw "INVALID_ARGUMENT"
      inventory := registry_.inventory
      rows := inventory[1].map: | info/BondInfo |
        [info.slot, info.local-address, info.local-address-type,
          info.peer-address, info.peer-address-type, info.authenticated]
      return index == api.BONDS ? rows : [inventory[0], rows]
    if index == api.REVOKE-IF-CURRENT:
      if arguments is not List or arguments.size != 2 or arguments[0] is not int or
          arguments[1] is not ByteArray or arguments[1].size != 16:
        throw "INVALID_ARGUMENT"
      registry_.remove arguments[0] --if-revision=arguments[1]
      return null
    if index != api.REVOKE: throw "BLE_BOND_ADMIN_UNSUPPORTED"
    if arguments is not int or not 0 <= arguments < 255: throw "INVALID_ARGUMENT"
    registry_.remove arguments
    return null
