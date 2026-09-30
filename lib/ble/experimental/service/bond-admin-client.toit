// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import system.services
import ..bond-info show BondInfo
import .bond-admin-api as api

/**
The client of the optional bond administration service.

A trusted administrator container uses $Client to list the provider's bonds
  as $BondInfo rows ($Client.bonds) and to revoke them ($Client.revoke,
  $Client.revoke-bond). The provider side is
  `ble.experimental.service.bond-admin-provider`; authorization is decided
  there, by container group.
*/

/**
An optional administrative client; discovery does not grant authorization.

Use the provider process restriction with an ID supplied by trusted
  launch code when selecting an administrative provider. A matching selector,
  service name or tag alone does not establish provider identity.
*/
class Client extends services.ServiceClient:
  constructor selector/services.ServiceSelector=api.SELECTOR --provider-pid/int?=null:
    if not (selector.matches api.SELECTOR): throw "INVALID_ARGUMENT"
    super selector --provider-pid=provider-pid

  /**
  Returns a bounded inventory of public bond metadata for an authorized caller.

  The provider serializes the snapshot with revocation and addition. No key or
    IRK is returned. The result does not prove live encryption or peer retention.
  */
  bonds --timeout/Duration=(Duration --s=30) -> List:
    if timeout.in-us <= 0: throw "INVALID_ARGUMENT"
    return with-timeout timeout:
      inventory := invoke_ api.BONDS-WITH-REVISION null
      if inventory is not List or inventory.size != 2 or
          inventory[0] is not ByteArray or inventory[0].size != 16:
        throw "BLE_BOND_ADMIN_BAD_RESPONSE"
      revision/ByteArray := inventory[0]
      rows := inventory[1]
      if rows is not List or rows.size > 255: throw "BLE_BOND_ADMIN_BAD_RESPONSE"
      previous := -1
      rows.map: | row/any |
        if row is not List or row.size != 6 or row[0] is not int or
            row[1] is not ByteArray or row[2] is not int or
            row[3] is not ByteArray or row[4] is not int or row[5] is not bool:
          throw "BLE_BOND_ADMIN_BAD_RESPONSE"
        if not previous < row[0] < 255 or row[1].size != 6 or row[3].size != 6 or
            not 0 <= row[2] <= 1 or not 0 <= row[4] <= 1:
          throw "BLE_BOND_ADMIN_BAD_RESPONSE"
        previous = row[0]
        BondInfo row[0] row[1] row[2]
            row[3]
            row[4]
            row[5]
            --revision=revision

  /**
  Revokes the selected inventory entry only while its snapshot is still current.

  Requires the same administrative authorization as $revoke. Any successful
    registry mutation or a new registry invalidates the opaque revision. Stale
    requests fail before closing live owners or changing storage; refresh the
    inventory and select again. This is not a persistent bond identifier.
    A timeout may occur after deletion commits; refresh to resolve the outcome.
  */
  revoke-bond info/BondInfo --timeout/Duration=(Duration --s=30) -> none:
    revision := info.revision
    if not revision or timeout.in-us <= 0: throw "INVALID_ARGUMENT"
    with-timeout timeout: invoke_ api.REVOKE-IF-CURRENT [info.slot, revision]

  /**
  Revokes a configured bond slot and its registry-tracked live owners.

  Requires provider authorization. Success follows verified storage removal;
    ambiguous failures retain the registry's fail-closed behavior. This does
    not return key material or grant permission to replace or provision bonds.
    A timeout cancels the RPC but cannot roll back a storage write already
    committed. Trusted provider code must resolve any ambiguous outcome.
  */
  revoke slot/int --timeout/Duration=(Duration --s=30) -> none:
    if not 0 <= slot < 255: throw "INVALID_ARGUMENT"
    if timeout.in-us <= 0: throw "INVALID_ARGUMENT"
    with-timeout timeout: invoke_ api.REVOKE slot
