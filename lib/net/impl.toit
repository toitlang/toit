// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor

import .net as net
import .tcp as tcp
import .udp as udp

import .modules.dns as dns
import .modules.tcp
import .modules.udp

import system.api.network show NetworkServiceClient NetworkResource

service_value_/NetworkServiceClient? := null
service_mutex_/monitor.Mutex ::= monitor.Mutex

service_ -> NetworkServiceClient?:
  return service_value_ or service_mutex_.do:
    service_value_ = (NetworkServiceClient --no-open).open

open -> net.Interface:
  service := service_
  if not service: throw "Network unavailable"
  return SystemInterface_ service

// TODO(kasper): Find a way to listen for network closing.
class SystemInterface_ extends NetworkResource implements net.Interface:
  constructor service/NetworkServiceClient:
    super service

  resolve host/string -> List:
    if not handle_: throw "Network closed"
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

  address -> net.IpAddress:
    if not handle_: throw "Network closed"
    return super
