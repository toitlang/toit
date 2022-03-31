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

import system.services show ServiceDefinition ServiceResource

import esp32
import .network
import .modules.wifi

WIFI_CONNECT_TIMEOUT_  ::= Duration --s=10
WIFI_DHCP_TIMEOUT_     ::= Duration --s=16

class WifiServiceDefinition extends NetworkServiceDefinition:
  state_/WifiState? := null

  connect client/int -> ServiceResource:
    return connect client null null

  connect client/int ssid/string? password/string? -> ServiceResource:
    if not ssid:
      config := esp32.image_config or {:}
      wifi_config := config.get "wifi" --if_absent=: {:}
      ssid = wifi_config["ssid"]
      password = wifi_config.get "password" --if_absent=: ""
    if not state_: state_ = WifiState this
    wifi ::= state_.up ssid password
    if wifi.ssid_ != ssid or wifi.password_ != password:
      throw "wifi already connected with different credentials"
    return WifiResource this client state_

  address resource/WifiResource -> ByteArray:
    return state_.wifi.address.to_byte_array

  turn_on ssid/string password/string -> Wifi:
    wifi := Wifi
    try:
      wifi.set_ssid ssid password
      with_timeout WIFI_CONNECT_TIMEOUT_: wifi.connect
      with_timeout WIFI_DHCP_TIMEOUT_: wifi.get_ip
      return wifi
    finally: | is_exception exception |
      if is_exception:
        wifi.close

  turn_off wifi/Wifi -> none:
    wifi.close

class WifiResource extends NetworkResource:
  state_/WifiState ::= ?
  constructor service/ServiceDefinition client/int .state_:
    super service client

  on_closed -> none:
    state_.down

monitor WifiState:
  service_/WifiServiceDefinition ::= ?
  wifi_/Wifi? := null
  usage_/int := 0
  constructor .service_:

  wifi -> Wifi?:
    return wifi_

  up ssid/string password/string -> Wifi:
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
