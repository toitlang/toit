// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import net.udp
import net.tcp
import monitor

import .modules.wifi as wifi
import .modules.tcp
import .modules.udp
import .modules.dns
import ..esp32

WIFI_CONNECT_TIMEOUT_  ::= Duration --s=10
WIFI_DHCP_TIMEOUT_     ::= Duration --s=16

wifi_/wifi.Wifi? := null
wifi_connecting_/monitor.Latch? := null

connect --ssid/string?=null --password/string="" -> net.Interface:
  if not ssid:
    config := image_config or {:}
    wifi_config := config.get "wifi" --if_absent=: {:}
    ssid = wifi_config.get "ssid"
    password = wifi_config.get "password"

  if not wifi_:
    if wifi_connecting_:
      // If we're already connecting, we wait and see if that leads to
      // an exception. If it doesn't throw, then we continue to mark
      // ourselves as a user of the WiFi network.
      exception := wifi_connecting_.get
      if exception: throw exception
    else:
      // We use a latch to coordinate the initial creation of the WiFi
      // connection. We always set it to a value when leaving this path
      // and we always clear out the latch when we're done synchronizing.
      wifi_connecting_ = monitor.Latch
      wifi := wifi.Wifi
      try:
        wifi.set_ssid ssid password
        with_timeout WIFI_CONNECT_TIMEOUT_: wifi.connect
        with_timeout WIFI_DHCP_TIMEOUT_: wifi.get_ip
        // Success: Register the WiFi connection, tell anyone who is waiting
        // for it that the connection is ready to be used (no exception), and
        // go on to mark ourselves as a user of the WiFi network.
        wifi_ = wifi
        wifi_connecting_.set null
      finally: | is_exception exception |
        if is_exception:
          wifi.close
          wifi_connecting_.set exception.value
        wifi_connecting_ = null

  interface := WifiInterface_
  if ssid == wifi_.ssid_ and password == wifi_.password_: return interface
  interface.close
  throw "wifi already connected with different credentials"

class WifiInterface_ extends net.Interface:
  static open_count_/int := 0
  open_/bool := true

  constructor:
    open_count_++

  resolve host/string -> List:
    with_wifi_:
      return [dns_lookup host]
    unreachable

  udp_open -> udp.Socket:
    return udp_open --port=null

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
    if not open_: return
    open_ = false
    if --open_count_ > 0: return
    wifi := wifi_
    wifi_ = null
    wifi.close

  with_wifi_ [block]:
    if not open_: throw "interface is closed"
    block.call wifi_
