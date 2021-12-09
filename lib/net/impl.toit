// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import wifi

import .net
import .tcp as tcp
import .udp as udp

import .modules.dns as dns
import .modules.tcp
import .modules.udp
import .modules.wifi

wifi_enabled_ := false

open -> Interface:
  if platform == "FreeRTOS":
    network := wifi.connect
    wifi_enabled_ = true
    return network
  return SystemInterface_

class SystemInterface_ extends Interface:
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
    return IpAddress.parse "0.0.0.0"

  close -> none:
    // Do nothing yet.
