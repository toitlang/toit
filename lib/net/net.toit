// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .net as net
import .tcp as tcp
import .udp as udp

import .ip_address
import .socket_address

import .modules.dns as dns_module
import .modules.tcp as tcp_module
import .modules.udp as udp_module

import system.api.network show NetworkService NetworkServiceClient
import system.base.network show NetworkResourceProxy

export IpAddress SocketAddress

service_/NetworkServiceClient? ::= (NetworkServiceClient).open
    --if_absent=: null

/// Gets the default network interface.
open -> Client
    --name/string?=null
    --service/NetworkServiceClient?=service_:
  if not service: throw "Network unavailable"
  return Client service --name=name service.connect

interface Interface implements udp.Interface tcp.Interface:
  name -> string
  address -> IpAddress
  is_closed -> bool

  resolve host/string -> List /* of IpAddress. */

  udp_open -> udp.Socket
  udp_open --port/int? -> udp.Socket

  tcp_connect host/string port/int -> tcp.Socket
  tcp_connect address/SocketAddress -> tcp.Socket
  tcp_listen port/int -> tcp.ServerSocket

  on_closed lambda/Lambda? -> none

  close -> none

class Client extends NetworkResourceProxy implements Interface:
  name/string

  // The proxy mask contains bits for all the operations that must be
  // proxied through the service client. The service definition tells the
  // client about the bits on connect.
  proxy_mask/int

  constructor service/NetworkServiceClient --name/string? connection/List:
    handle := connection[0]
    proxy_mask = connection[1]
    this.name = name or connection[2]
    super service handle

  constructor service/NetworkServiceClient
      --handle/int
      --.proxy_mask
      --.name:
    super service handle

  address -> IpAddress:
    if is_closed: throw "Network closed"
    if (proxy_mask & NetworkService.PROXY_ADDRESS) != 0: return super
    socket := udp_module.Socket
    try:
      // This doesn't actually cause any network traffic, but it picks an
      // interface for 8.8.8.8, which is not on the LAN.
      socket.connect
          SocketAddress
              IpAddress.parse "8.8.8.8"
              80
      // Get the IP of the default interface.
      return socket.local_address.ip
    finally:
      socket.close

  resolve host/string -> List /* of IpAddress */:
    if is_closed: throw "Network closed"
    if (proxy_mask & NetworkService.PROXY_RESOLVE) != 0: return super host
    return [dns_module.dns_lookup host]

  quarantine -> none:
    if (proxy_mask & NetworkService.PROXY_QUARANTINE) == 0: return
    (client_ as NetworkServiceClient).quarantine name

  udp_open --port/int?=null -> udp.Socket:
    if is_closed: throw "Network closed"
    if (proxy_mask & NetworkService.PROXY_UDP) != 0: return super --port=port
    return udp_module.Socket "0.0.0.0" (port ? port : 0)

  tcp_connect host/string port/int -> tcp.Socket:
    ips := resolve host
    return tcp_connect
        SocketAddress ips[0] port

  tcp_connect address/net.SocketAddress -> tcp.Socket:
    if is_closed: throw "Network closed"
    if (proxy_mask & NetworkService.PROXY_TCP) != 0: return super address
    result := tcp_module.TcpSocket
    result.connect address.ip.stringify address.port
    return result

  tcp_listen port/int -> tcp.ServerSocket:
    if is_closed: throw "Network closed"
    if (proxy_mask & NetworkService.PROXY_TCP) != 0: return super port
    result := tcp_module.TcpServerSocket
    result.listen "0.0.0.0" port
    return result

  on_notified_ notification/any -> none:
    if notification == NetworkService.NOTIFY_CLOSED: close_handle_
