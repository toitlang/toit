// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .wifi as wifi

import .net
import .tcp as tcp
import .udp as udp

import .modules.dns as dns
import .modules.tcp
import .modules.udp
import .modules.wifi

WIFI_ALREADY_STARTED_EXCEPTION_ ::= "OUT_OF_BOUNDS"

open -> Interface:
  if platform == PLATFORM_FREERTOS:
    // We fall through and use the system interface if the WiFi was already started
    // in another process. This is broken because the other process might close
    // the WiFi and it really shouldn't while this process is still using it.
    catch --unwind=(: it != WIFI_ALREADY_STARTED_EXCEPTION_):
      return wifi.connect
    // Temporary work-around for two processes opening the network at the same time.
    // The `WIFI_ALREADY_STARTED_EXCEPTION_` is thrown when another thread already
    // opened the network. However, at this point we aren't sure whether the
    // the network is already connected. We therefore look at the stored IP address.
    // As soon as that one is available we know that we can use the network.
    with_timeout --ms=26_000:
      while true:
        // Wait for the other thread to store the IP.
        if stored_ip_ != "": break
        sleep --ms=100
  return SystemInterface_

class SystemInterface_ extends Interface:
  resolve host/string -> List:
    return [dns.dns_lookup host]

  udp_open -> udp.Socket:
    return udp_open --port=null

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
    if platform == PLATFORM_FREERTOS:
      return IpAddress.parse stored_ip_

    socket := udp_open
    try:
      socket.connect
        SocketAddress
          IpAddress.parse "8.8.8.8"
          80
      return socket.local_address.ip
    finally:
      socket.close

  close -> none:
    // Do nothing yet.

stored_ip_ -> string:
  #primitive.wifi.get_stored_ip
