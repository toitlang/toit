// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .net
import .tcp as tcp
import .udp as udp

import .modules.dns as dns
import .modules.tcp
import .modules.udp

open -> Interface:
  return InterfaceImpl_

class InterfaceImpl_ extends Interface:
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
