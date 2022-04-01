// Copyright (C) 2022 Toitware ApS.
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
import esp32

import system.api.wifi show WifiService
import system.api.network show NetworkService
import system.services show ServiceDefinition ServiceResource

import ..shared.network_base

WIFI_CONNECT_TIMEOUT_ ::= Duration --s=10
WIFI_DHCP_TIMEOUT_    ::= Duration --s=16

class WifiServiceDefinition extends NetworkServiceDefinitionBase:
  state_/WifiState? := null

  constructor:
    super "$WifiService.NAME/esp32" --major=0 --minor=1
    alias WifiService.NAME --major=WifiService.MAJOR --minor=WifiService.MINOR
    alias NetworkService.NAME --major=NetworkService.MAJOR --minor=NetworkService.MINOR

  handle pid/int client/int index/int arguments/any -> any:
    if index == WifiService.CONNECT_SSID_PASSWORD_INDEX:
      return connect client arguments[0] arguments[1]
    return super pid client index arguments

  connect client/int -> ServiceResource:
    return connect client null null

  connect client/int ssid/string? password/string? -> ServiceResource:
    if not ssid:
      config := esp32.image_config or {:}
      wifi_config := config.get "wifi" --if_absent=: {:}
      ssid = wifi_config["ssid"]
      password = wifi_config.get "password" --if_absent=: ""
    if not state_: state_ = WifiState this
    module ::= state_.up ssid password
    if module.ssid_ != ssid or module.password_ != password:
      throw "wifi already connected with different credentials"
    return WifiResource this client state_

  address resource/WifiResource -> ByteArray:
    return state_.wifi.address.to_byte_array

  turn_on ssid/string password/string -> WifiModule:
    module := WifiModule
    try:
      module.set_ssid ssid password
      with_timeout WIFI_CONNECT_TIMEOUT_: module.connect
      with_timeout WIFI_DHCP_TIMEOUT_: module.get_ip
      return module
    finally: | is_exception exception |
      if is_exception:
        module.close

  turn_off module/WifiModule -> none:
    module.close

class WifiResource extends ServiceResource:
  state_/WifiState ::= ?
  constructor service/ServiceDefinition client/int .state_:
    super service client

  on_closed -> none:
    state_.down

monitor WifiState:
  service_/WifiServiceDefinition ::= ?
  wifi_/WifiModule? := null
  usage_/int := 0
  constructor .service_:

  wifi -> WifiModule?:
    return wifi_

  up ssid/string password/string -> WifiModule:
    usage_++
    if wifi_: return wifi_
    return wifi_ = service_.turn_on ssid password

  down -> none:
    usage_--
    if usage_ > 0 or not wifi_: return
    try:
      service_.turn_off wifi_
    finally:
      // Assume the WiFi is off even if turning
      // it off threw an exception.
      wifi_ = null

class WifiModule:
  static WIFI_CONNECTED    ::= 1 << 0
  static WIFI_DHCP_SUCCESS ::= 1 << 1
  static WIFI_DISCONNECTED ::= 1 << 2
  static WIFI_RETRY        ::= 1 << 3

  logger_/log.Logger ::= log.default.with_name "wifi"

  resource_group_ := wifi_init_

  ssid_ := null
  password_ := null

  address_/net.IpAddress? := null

  set_ssid ssid password:
    ssid_ = ssid
    password_ = password

  close:
    if resource_group_:
      logger_.debug "closing"
      wifi_close_ resource_group_
      resource_group_ = null

  address -> net.IpAddress:
    return address_

  connect:
    try:
      logger_.debug "connecting"
      while true:
        resource := wifi_connect_ resource_group_ ssid_ password_
        res := monitor.ResourceState_ resource_group_ resource
        state := res.wait
        res.dispose
        if (state & WIFI_CONNECTED) != 0:
          logger_.debug "connected"
          return
        else if (state & WIFI_RETRY) != 0:
          reason ::= wifi_disconnect_reason_ resource
          logger_.info "retrying" --tags={"reason": reason}
          wifi_disconnect_ resource_group_ resource
          sleep --ms=1_000  // Retry with 1s delay.
          continue
        else if (state & WIFI_DISCONNECTED) != 0:
          reason ::= wifi_disconnect_reason_ resource
          logger_.warn "connect failed" --tags={"reason": reason}
          close
          throw "CONNECT_FAILED: $reason"
    finally: | is_exception exception |
      if is_exception and exception.value == DEADLINE_EXCEEDED_ERROR:
        logger_.warn "connect failed" --tags={"reason": "timeout"}

  get_ip:
    resource := wifi_setup_ip_ resource_group_
    res := monitor.ResourceState_ resource_group_ resource
    state := res.wait
    res.dispose
    if (state & WIFI_DHCP_SUCCESS) != 0:
      ip := wifi_get_ip_ resource
      address_ = net.IpAddress.parse ip
      logger_.info "dhcp assigned address" --tags={"ip": ip}
      return ip
    close
    throw "IP_ASSIGN_FAILED"

  rssi -> int?:
    return wifi_get_rssi_ resource_group_

// ----------------------------------------------------------------------------

wifi_init_:
  #primitive.wifi.init

wifi_close_ resource_group:
  #primitive.wifi.close

wifi_connect_ resource_group ssid password:
  #primitive.wifi.connect

wifi_setup_ip_ resource_group:
  #primitive.wifi.setup_ip

wifi_disconnect_ resource_group resource:
  #primitive.wifi.disconnect

wifi_disconnect_reason_ resource:
  #primitive.wifi.disconnect_reason

wifi_get_ip_ resource:
  #primitive.wifi.get_ip

wifi_get_rssi_ resource_group:
  #primitive.wifi.get_rssi
