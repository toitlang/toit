// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .net
import .tcp as tcp
import .udp as udp

import .modules.dns as dns
import .modules.tcp
import .modules.udp
import .modules.wifi

WIFI_USE_      /bool   ::= (platform == "FreeRTOS") and (WIFI_SSID_ != "")
WIFI_SSID_     /string ::= defines_.get "wifi.ssid" --if_absent=: ""
WIFI_PASSWORD_ /string ::= defines_.get "wifi.password" --if_absent=: ""
WIFI_CONNECT_TIMEOUT_  ::= Duration --s=10
WIFI_DHCP_TIMEOUT_     ::= Duration --s=16

wifi_enabled_ := false

open -> Interface:
  wifi := null
  if WIFI_USE_ and not wifi_enabled_:
    wifi = Wifi
    try:
      wifi.set_ssid WIFI_SSID_ WIFI_PASSWORD_
      with_timeout WIFI_CONNECT_TIMEOUT_: wifi.connect
      with_timeout WIFI_DHCP_TIMEOUT_: wifi.get_ip
      wifi_enabled_ = true
    finally: | is_exception _ |
      if is_exception: wifi.close
  return InterfaceImpl_ wifi

class InterfaceImpl_ extends Interface:
  wifi_/Wifi?

  constructor .wifi_:

  resolve host/string -> List:
    return [dns.dns_lookup host]

  udp_open -> udp.Socket: return udp_open --port=null
  udp_open --port/int? -> udp.Socket:
    return Socket "0.0.0.0" (port ? port : 0)

  tcp_connect address/SocketAddress -> tcp.Socket:
    result := TcpSocket
    result.connect address.ip.stringify address.port
    return result

  tcp_listen port/int -> tcp.ServerSocket:
    result := TcpServerSocket
    result.listen "0.0.0.0" port
    return result

  address -> IpAddress:
    if wifi_:
      return wifi_.address
    return IpAddress.parse "0.0.0.0"

  close -> none:
    // Do nothing yet.
