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
import system.base.network show NetworkModule NetworkResource NetworkState

import ..shared.network_base

class WifiServiceDefinition extends NetworkServiceDefinitionBase:
  state_/NetworkState? := null

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

    if not state_: state_ = NetworkState
    module ::= state_.up: WifiModule this ssid password
    // TODO(kasper): Re-enable this check.
    // if module.ssid != ssid or module.password != password:
    //   throw "wifi already connected with different credentials"

    resource := NetworkResource this client state_ --notifiable
    return [resource.serialize_for_rpc, NetworkService.PROXY_ADDRESS]

  address resource/NetworkResource -> ByteArray:
    return (state_.module as WifiModule).address.to_byte_array

  on_module_closed module/WifiModule -> none:
    resources_do_: it.notify_ NetworkService.NOTIFY_CLOSED
    state_ = null

class WifiModule implements NetworkModule:
  static WIFI_CONNECTED    ::= 1 << 0
  static WIFI_IP_ASSIGNED  ::= 1 << 1
  static WIFI_IP_LOST      ::= 1 << 2
  static WIFI_DISCONNECTED ::= 1 << 3
  static WIFI_RETRY        ::= 1 << 4

  static WIFI_RETRY_DELAY_     ::= Duration --s=1
  static WIFI_CONNECT_TIMEOUT_ ::= Duration --s=10
  static WIFI_DHCP_TIMEOUT_    ::= Duration --s=16

  logger_/log.Logger ::= log.default.with_name "wifi"
  service/WifiServiceDefinition
  ssid/string
  password/string

  resource_group_ := wifi_init_
  wifi_events_/monitor.ResourceState_? := null
  ip_events_/monitor.ResourceState_? := null
  address_/net.IpAddress? := null

  constructor .service .ssid .password:
    // Do nothing that can fail.

  address -> net.IpAddress:
    return address_

  connect -> none:
    with_timeout WIFI_CONNECT_TIMEOUT_: wait_for_connected_
    with_timeout WIFI_DHCP_TIMEOUT_: wait_for_ip_address_

  disconnect -> none:
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
    service.on_module_closed this

  wait_for_connected_:
    try:
      logger_.debug "connecting"
      while true:
        resource := wifi_connect_ resource_group_ ssid password
        wifi_events_ = monitor.ResourceState_ resource_group_ resource
        state := wifi_events_.wait
        if (state & WIFI_CONNECTED) != 0:
          wifi_events_.clear_state WIFI_CONNECTED
          logger_.debug "connected"
          wifi_events_.set_callback:: on_event_ it
          return
        else if (state & WIFI_RETRY) != 0:
          // We will be creating a new ResourceState object on the next
          // iteration, so we need to dispose the one from this attempt.
          wifi_events_.dispose
          wifi_events_ = null
          reason ::= wifi_disconnect_reason_ resource
          logger_.info "retrying" --tags={"reason": reason}
          wifi_disconnect_ resource_group_ resource
          sleep WIFI_RETRY_DELAY_
          continue
        else if (state & WIFI_DISCONNECTED) != 0:
          reason ::= wifi_disconnect_reason_ resource
          logger_.warn "connect failed" --tags={"reason": reason}
          throw "CONNECT_FAILED: $reason"
    finally: | is_exception exception |
      if is_exception and exception.value == DEADLINE_EXCEEDED_ERROR:
        logger_.warn "connect failed" --tags={"reason": "timeout"}

  wait_for_ip_address_ -> net.IpAddress:
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
    throw "IP_ASSIGN_FAILED"

  rssi -> int?:
    return wifi_get_rssi_ resource_group_

  on_event_ state/int:
    // TODO(kasper): We should be clearing the state in the
    // $monitor.ResourceState_ object, but since we're only
    // closing here it doesn't really matter. Room for
    // improvement though.
    if (state & (WIFI_DISCONNECTED | WIFI_IP_LOST)) != 0:
      task:: disconnect

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
