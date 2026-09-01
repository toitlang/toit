// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .net as net
import .tcp as tcp
import .udp as udp

import .ip-address
import .socket-address

import .modules.dns as dns-module
import .modules.tcp as tcp-module
import .modules.udp as udp-module

import system.api.network show NetworkService NetworkServiceClient
import system.base.network show NetworkServiceClientBase
import system.base.network show NetworkResourceProxy

export IpAddress SocketAddress

service_/NetworkServiceClient? ::= (NetworkServiceClient).open
    --if-absent=: null

/// Gets the default network interface.
open -> Client
    --name/string?=null
    --service/NetworkServiceClientBase?=service_:
  if not service: throw "Network unavailable"
  return Client service --name=name service.connect

interface Interface implements udp.Interface tcp.Interface:
  name -> string
  address -> IpAddress
  is-closed -> bool

  resolve host/string -> List /* of IpAddress. */

  udp-open -> udp.Socket
  udp-open --port/int? -> udp.Socket

  tcp-connect host/string port/int -> tcp.Socket
  tcp-connect address/SocketAddress -> tcp.Socket
  tcp-listen port/int -> tcp.ServerSocket

  on-closed lambda/Lambda? -> none

  close -> none

class Client extends NetworkResourceProxy implements Interface udp.MulticastInterface:
  name/string

  // The proxy mask contains bits for all the operations that must be
  // proxied through the service client. The service definition tells the
  // client about the bits on connect.
  proxy-mask/int

  constructor service/NetworkServiceClientBase --name/string? connection/List:
    handle := connection[0]
    proxy-mask = connection[1]
    this.name = name or connection[2]
    super service handle

  constructor service/NetworkServiceClientBase
      --handle/int
      --.proxy-mask
      --.name:
    super service handle

  address -> IpAddress:
    if is-closed: throw "Network closed"
    if (proxy-mask & NetworkService.PROXY-ADDRESS) != 0: return super
    socket := udp-module.Socket this
    try:
      // This doesn't actually cause any network traffic, but it picks an
      // interface for 8.8.8.8, which is not on the LAN.
      socket.connect
          SocketAddress
              IpAddress.parse "8.8.8.8"
              80
      // Get the IP of the default interface.
      return socket.local-address.ip
    finally:
      socket.close

  resolve host/string -> List /* of IpAddress */:
    if is-closed: throw "Network closed"
    if (proxy-mask & NetworkService.PROXY-RESOLVE) != 0: return super host
    return dns-module.dns-lookup-multi host --network=this

  quarantine -> none:
    if (proxy-mask & NetworkService.PROXY-QUARANTINE) == 0: return
    (client_ as NetworkServiceClientBase).quarantine name

  udp-open --port/int?=null -> udp.Socket:
    if is-closed: throw "Network closed"
    if (proxy-mask & NetworkService.PROXY-UDP) != 0: return super --port=port
    return udp-module.Socket this "0.0.0.0" (port ? port : 0)

  udp-open-multicast -> udp.MulticastSocket
      address/IpAddress
      port/int
      --if-addr/IpAddress?=null
      --reuse-address/bool=true
      --reuse-port/bool=false
      --loopback/bool=true
      --ttl/int=1:
    if is-closed: throw "Network closed"
    if (proxy-mask & NetworkService.PROXY-UDP) != 0:
      return super
          address
          port
          --if-addr=if-addr
          --reuse-address=reuse-address
          --reuse-port=reuse-port
          --loopback=loopback
          --ttl=ttl
    return udp-module.Socket.multicast this
        address
        port
        --if-addr=if-addr
        --reuse-address=reuse-address
        --reuse-port=reuse-port
        --loopback=loopback
        --ttl=ttl

  tcp-connect host/string port/int -> tcp.Socket:
    ips := resolve host
    return tcp-connect
        SocketAddress
            dns-module.select-random-ip_ host ips
            port

  tcp-connect address/net.SocketAddress -> tcp.Socket:
    if is-closed: throw "Network closed"
    if (proxy-mask & NetworkService.PROXY-TCP) != 0: return super address
    result := tcp-module.TcpSocket this
    result.connect address.ip.stringify address.port
    return result

  tcp-listen port/int -> tcp.ServerSocket:
    if is-closed: throw "Network closed"
    if (proxy-mask & NetworkService.PROXY-TCP) != 0: return super port
    result := tcp-module.TcpServerSocket this
    result.listen "0.0.0.0" port
    return result

  on-notified_ notification/any -> none:
    if notification == NetworkService.NOTIFY-CLOSED: close-handle_
