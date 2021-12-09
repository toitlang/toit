// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import net.udp
import net.tcp

import .net.modules.wifi as wifi
import .net.modules.tcp
import .net.modules.udp
import .net.modules.dns
import .esp32

WIFI_CONNECT_TIMEOUT_  ::= Duration --s=10
WIFI_DHCP_TIMEOUT_     ::= Duration --s=16

connect --ssid/string?=null --password/string="" -> Wifi:
  if not ssid:
    config := image_config or {:}
    wifi_config := config.get "wifi" --if_absent=: {:}
    ssid = wifi_config.get "ssid"
    password = wifi_config.get "password"

  wifi := wifi.Wifi
  try:
    wifi.set_ssid ssid password
    with_timeout WIFI_CONNECT_TIMEOUT_: wifi.connect
    with_timeout WIFI_DHCP_TIMEOUT_: wifi.get_ip
    return Wifi wifi
  finally: | is_exception _ |
    if is_exception: wifi.close

class Wifi extends net.Interface:
  wifi_/wifi.Wifi? := ?

  constructor .wifi_:

  resolve host/string -> List:
    with_wifi_:
      return [dns_lookup host]
    unreachable

  udp_open -> udp.Socket: return udp_open --port=null
  udp_open --port/int? -> udp.Socket:
    with_wifi_:
      return Socket "0.0.0.0" (port ? port : 0)
    unreachable

  tcp_connect address/net.SocketAddress -> tcp.Socket:
    with_wifi_:
      result := TcpSocket
      result.connect address.ip.stringify address.port
      return result
    unreachable

  tcp_listen port/int -> tcp.ServerSocket:
    with_wifi_:
      result := TcpServerSocket
      result.listen "0.0.0.0" port
      return result
    unreachable

  address -> net.IpAddress:
    with_wifi_:
      return it.address
    unreachable

  close -> none:
    if wifi_:
      wifi_.close
      wifi_ = null

  with_wifi_ [block]:
    if not wifi_: throw "interface is closed"
    block.call wifi_
