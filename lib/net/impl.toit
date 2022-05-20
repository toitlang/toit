// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .net as net
import .tcp as tcp
import .udp as udp
import .socket_address

import .modules.dns as dns
import .modules.tcp
import .modules.udp

import system.api.network show NetworkService NetworkServiceClient NetworkResource

service_/NetworkServiceClient? ::= (NetworkServiceClient --no-open).open

open -> net.Interface:
  service := service_
  if not service: throw "Network unavailable"
  return SystemInterface_ service service.connect

// TODO(kasper): Find a way to listen for network closing.
class SystemInterface_ extends NetworkResource implements net.Interface:
  // The proxy mask contains bits for all the operations that must be
  // proxied through the service client. The service definition tells the
  // client about the bits on connect.
  proxy_mask_/int ::= ?

  constructor service/NetworkServiceClient connection/List:
    handle := connection[0]
    proxy_mask_ = connection[1]
    super service handle

  address -> net.IpAddress:
    if not handle_: throw "Network closed"
    if (proxy_mask_ & NetworkService.PROXY_ADDRESS) != 0: return super
    socket := Socket
    try:
      socket.connect
          SocketAddress
              net.IpAddress.parse "8.8.8.8"
              80
      return socket.local_address.ip
    finally:
      socket.close

  resolve host/string -> List:
    if not handle_: throw "Network closed"
    if (proxy_mask_ & NetworkService.PROXY_RESOLVE) != 0: return super host
    return [dns.dns_lookup host]

  udp_open --port/int?=null -> udp.Socket:
    if not handle_: throw "Network closed"
    return Socket "0.0.0.0" (port ? port : 0)

  tcp_connect host/string port/int -> tcp.Socket:
    ips := resolve host
    return tcp_connect
        net.SocketAddress ips[0] port

  tcp_connect address/net.SocketAddress -> tcp.Socket:
    if not handle_: throw "Network closed"
    result := TcpSocket
    result.connect address.ip.stringify address.port
    return result

  tcp_listen port/int -> tcp.ServerSocket:
    if not handle_: throw "Network closed"
    result := TcpServerSocket
    result.listen "0.0.0.0" port
    return result
