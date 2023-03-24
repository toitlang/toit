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
open --service/NetworkServiceClient?=service_ -> Client:
  if not service: throw "Network unavailable"
  return Client service service.connect

interface Interface implements udp.Interface tcp.Interface:
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
  // The proxy mask contains bits for all the operations that must be
  // proxied through the service client. The service definition tells the
  // client about the bits on connect.
  proxy_mask/int

  // ...
  id/string?

  constructor service/NetworkServiceClient connection/List:
    handle := connection[0]
    proxy_mask = connection[1]
    id = (connection.size < 3) ? null : connection[2]
    super service handle

  constructor service/NetworkServiceClient
      --handle/int
      --.proxy_mask
      --.id=null:
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

  report --unavailable/bool -> none
      --dns/bool=false
      --internet/bool=false
      --data/bool=false:
    if not unavailable: throw "Bad Argument"
    if not id or (proxy_mask & NetworkService.PROXY_REPORT) == 0: return
    events := NetworkService.EVENT_NONE
    if dns: events |= NetworkService.EVENT_NO_DNS
    if internet: events |= NetworkService.EVENT_NO_INTERNET
    if data: events |= NetworkService.EVENT_NO_DATA
    (client_ as NetworkServiceClient).report id events

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
