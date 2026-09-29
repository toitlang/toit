// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import ..central as central
import ..connection as connection
import ..gatt-server as gatt
import .api as api

/** Tests whether $index names one of the link operations handled here. */
is-link-operation index/int -> bool:
  return api.LINK-INFO <= index <= api.WAIT-DISCONNECTED

/**
Runs a link operation for a session that owns $link on $host.

Shared by central connections and peripheral sessions. LINK-INFO returns
  [role, tx PHY, rx PHY, tx octets, rx octets, interval, latency, supervision
  timeout, peer address, peer address type, identity address or null,
  identity address type or null]; the PHY is 1M and the octets
  27 until the controllers report otherwise. WAIT-DISCONNECTED returns the
  HCI reason once the link has ended.
*/
link-operation host/central.Central link/central.Link index/int arguments/List
    --server/gatt.Server?=null -> any:
  // RPC carries strings; controller errors are objects.
  result := null
  error := catch: result = link-operation_ host link index arguments server
  if error is string: throw error
  if error: throw error.stringify
  return result

link-operation_ host/central.Central link/central.Link index/int arguments/List server/gatt.Server? -> any:
  if index == api.LINK-INFO:
    if not arguments.is-empty: throw "INVALID_ARGUMENT"
    phy := link.phy
    length := link.data-length
    parameters := link.parameters
    return [
      link.info.role,
      phy ? phy.tx : connection.Phy.PHY-1M,
      phy ? phy.rx : connection.Phy.PHY-1M,
      length ? length.tx-octets : 27,
      length ? length.rx-octets : 27,
      parameters.interval,
      parameters.latency,
      parameters.supervision-timeout,
      link.info.address.copy,
      link.info.address-type,
      link.info.identity-address and link.info.identity-address.copy,
      link.info.identity-address-type,
    ]
  if index == api.WAIT-DISCONNECTED:
    if not arguments.is-empty: throw "INVALID_ARGUMENT"
    return link.wait-disconnected
  if not link.connected: throw "HCI_LINK_DISCONNECTED"
  if index == api.SET-PHY:
    if arguments.size != 2: throw "INVALID_ARGUMENT"
    phy := host.set-phy link --tx=arguments[0] --rx=arguments[1]
    return [phy.tx, phy.rx]
  if index == api.READ-RSSI:
    if not arguments.is-empty: throw "INVALID_ARGUMENT"
    return host.read-rssi link
  if index == api.READ-TX-POWER:
    if arguments.size != 1 or arguments[0] is not bool: throw "INVALID_ARGUMENT"
    return host.read-tx-power link --maximum=arguments[0]
  if index == api.UPDATE-PARAMETERS:
    if arguments.size != 4: throw "INVALID_ARGUMENT"
    if link.info.role == 1:
      // A peripheral asks the central through L2CAP signaling.
      if not server: throw "GATT_UNSUPPORTED_SERVICE_OPERATION"
      applied := server.update-parameters
          --interval-min=arguments[0]
          --interval-max=arguments[1]
          --latency=arguments[2]
          --supervision-timeout=arguments[3]
      return [applied.interval, applied.latency, applied.supervision-timeout]
    update := host.update-parameters link
        --interval-min=arguments[0]
        --interval-max=arguments[1]
        --latency=arguments[2]
        --supervision-timeout=arguments[3]
    return [update.interval, update.latency, update.supervision-timeout]
  throw "GATT_UNSUPPORTED_SERVICE_OPERATION"
