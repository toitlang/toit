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

WIFI_RETRY_DELAY_     ::= Duration --s=1
WIFI_CONNECT_TIMEOUT_ ::= Duration --s=10
WIFI_DHCP_TIMEOUT_    ::= Duration --s=16

class WifiServiceDefinition extends NetworkServiceDefinitionBase:
  state_/WifiState? := null

  constructor:
    super "system/wifi/esp32" --major=0 --minor=1
    provides WifiService.UUID WifiService.MAJOR WifiService.MINOR

  handle pid/int client/int index/int arguments/any -> any:
    if index == WifiService.CONNECT_SSID_PASSWORD_INDEX:
      return connect client arguments[0] arguments[1]
    return super pid client index arguments

  connect client/int -> List:
    return connect client null null

  connect client/int ssid/string? password/string? -> List:
    if not ssid:
      config := esp32.image_config or {:}
      wifi_config := config.get "wifi" --if_absent=: {:}
      ssid = wifi_config["ssid"]
      password = wifi_config.get "password" --if_absent=: ""
    if not state_: state_ = WifiState this
    module ::= state_.up ssid password
    if module.ssid_ != ssid or module.password_ != password:
      throw "wifi already connected with different credentials"
    resource := WifiResource this client state_
    return [resource.serialize_for_rpc, NetworkService.PROXY_ADDRESS]

  address resource/WifiResource -> ByteArray:
    return state_.wifi.address.to_byte_array

  turn_on ssid/string password/string -> WifiModule:
    module := WifiModule
    try:
      module.set_ssid ssid password
      with_timeout WIFI_CONNECT_TIMEOUT_: module.connect
      with_timeout WIFI_DHCP_TIMEOUT_: module.wait_for_ip
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
  static WIFI_IP_ASSIGNED  ::= 1 << 1
  static WIFI_IP_LOST      ::= 1 << 2
  static WIFI_DISCONNECTED ::= 1 << 3
  static WIFI_RETRY        ::= 1 << 4

  logger_/log.Logger ::= log.default.with_name "wifi"

  resource_group_ := wifi_init_

  wifi_events_/monitor.ResourceState_? := null
  ip_events_/monitor.ResourceState_? := null

  ssid_ := null
  password_ := null

  address_/net.IpAddress? := null

  set_ssid ssid password:
    ssid_ = ssid
    password_ = password

  close:
    if not resource_group_:
      return
    if wifi_events_:
      wifi_events_.dispose
      wifi_events_ = null
    if ip_events_:
      ip_events_.dispose
      ip_events_ = null
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
        wifi_events_ = monitor.ResourceState_ resource_group_ resource
        state := wifi_events_.wait
        if (state & WIFI_CONNECTED) != 0:
          wifi_events_.clear_state WIFI_CONNECTED
          logger_.debug "connected"
          wifi_events_.set_callback:: on_event_ it
          return
        else if (state & WIFI_RETRY) != 0:
          wifi_events_.clear_state WIFI_RETRY
          reason ::= wifi_disconnect_reason_ resource
          logger_.info "retrying" --tags={"reason": reason}
          wifi_disconnect_ resource_group_ resource
          sleep WIFI_RETRY_DELAY_
          continue
        else if (state & WIFI_DISCONNECTED) != 0:
          wifi_events_.clear_state WIFI_DISCONNECTED
          reason ::= wifi_disconnect_reason_ resource
          logger_.warn "connect failed" --tags={"reason": reason}
          close
          throw "CONNECT_FAILED: $reason"
    finally: | is_exception exception |
      if is_exception and exception.value == DEADLINE_EXCEEDED_ERROR:
        logger_.warn "connect failed" --tags={"reason": "timeout"}

  wait_for_ip_address -> net.IpAddress:
    resource := wifi_setup_ip_ resource_group_
    ip_events_ = monitor.ResourceState_ resource_group_ resource
    state := ip_events_.wait
    if (state & WIFI_IP_ASSIGNED) != 0:
      ip_events_.clear_state WIFI_IP_ASSIGNED
      ip/string ::= wifi_get_ip_ resource
      logger_.info "dhcp assigned address" --tags={"ip": ip}
      address ::= net.IpAddress.parse ip
      address_ = address
      ip_events_.set_callback:: on_event_ it
      return address
    else if (state & WIFI_IP_LOST) != 0:
      ip_events_.clear_state WIFI_IP_LOST
    close
    throw "IP_ASSIGN_FAILED"

  rssi -> int?:
    return wifi_get_rssi_ resource_group_

  on_event_ state/int:
    print_ "[callback] got wifi event: $state"

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
