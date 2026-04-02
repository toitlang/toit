// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import net
import monitor
import log

import net.modules.dns as dns-module
import net.modules.udp as udp-module
import net.udp

import system
import system.api.cellular show CellularService
import system.api.network show NetworkService
import system.services show ServiceResource
import system.base.network show NetworkModule NetworkResource NetworkState

import ..shared.network-base

// Keep in sync with the definitions in CellularResourceGroup.
CELLULAR-DETACHED_ ::= 1
CELLULAR-ATTACHED_ ::= 2

class CellularServiceProvider extends NetworkServiceProviderBase implements udp.Interface:
  state_/NetworkState ::= NetworkState

  constructor:
    super "system/cellular/ec618" --major=0 --minor=1
        --tags=[NetworkService.TAG-CELLULAR]
    provides CellularService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == CellularService.CONNECT-INDEX:
      return connect client arguments
    return super index arguments --gid=gid --client=client

  connect client/int -> List:
    return connect client null

  connect client/int config/Map? -> List:
    module := (state_.up: CellularModule this) as CellularModule
    succeeded := false
    try:
      resource := NetworkResource this client state_ --notifiable
      succeeded = true
      return [
        resource.serialize-for-rpc,
        NetworkService.PROXY-ADDRESS | NetworkService.PROXY-RESOLVE,
        "cellular",
      ]
    finally:
      if not succeeded:
        critical-do: state_.down

  address resource/NetworkResource -> ByteArray:
    return (state_.module as CellularModule).address.to-byte-array

  resolve resource/ServiceResource host/string -> List:
    return (dns-module.dns-lookup-multi host --network=this).map: it.raw

  on-module-closed module/CellularModule -> none:
    critical-do:
      resources-do: | resource/NetworkResource |
        if not resource.is-closed:
          resource.notify_ NetworkService.NOTIFY-CLOSED --close

  // Implements udp.Interface to allow DNS resolution over cellular.
  udp-open --port/int?=null -> udp.Socket:
    return udp-module.Socket this "0.0.0.0" (port ? port : 0)

class CellularModule implements NetworkModule:
  static CONNECT-TIMEOUT_ ::= Duration --s=60

  logger_/log.Logger ::= log.default.with-name "cellular"
  service/CellularServiceProvider

  resource-group_ := ?
  events_/monitor.ResourceState_? := null
  address_/net.IpAddress? := null

  constructor .service:
    resource-group_ = cellular-init_

  address -> net.IpAddress:
    return address_

  connect -> none:
    logger_.debug "connecting"
    resource := cellular-connect_ resource-group_
    events_ = monitor.ResourceState_ resource-group_ resource
    with-timeout CONNECT-TIMEOUT_:
      while true:
        state := events_.wait
        if (state & CELLULAR-ATTACHED_) != 0:
          events_.clear-state CELLULAR-ATTACHED_
          ip := (cellular-get-ip_ resource-group_ 0) or #[0, 0, 0, 0]
          address_ = net.IpAddress ip
          logger_.info "connected" --tags={"ip": address_}
          events_.set-callback:: on-event_ it
          return
        if (state & CELLULAR-DETACHED_) != 0:
          events_.clear-state CELLULAR-DETACHED_
          // Keep waiting for attachment.

  disconnect -> none:
    if not resource-group_: return
    critical-do:
      logger_.debug "closing"
      if events_:
        events_.dispose
        events_ = null
    cellular-close_ resource-group_
    resource-group_ = null
    address_ = null
    service.on-module-closed this

  on-event_ state/int:
    if (state & CELLULAR-DETACHED_) != 0: disconnect

// ----------------------------------------------------------------------------

cellular-init_:
  #primitive.cellular.init

cellular-close_ resource-group:
  #primitive.cellular.close

cellular-connect_ resource-group:
  #primitive.cellular.connect

cellular-disconnect_ resource-group resource:
  #primitive.cellular.disconnect

cellular-get-ip_ resource-group index/int -> ByteArray?:
  #primitive.cellular.get-ip
