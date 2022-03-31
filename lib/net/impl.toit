// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor

import .net
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

open -> Interface:
  service := service_
  if not service: throw "Network unavailable"
  network := NetworkResource.connect service_
  return SystemInterface_ network

// TODO(kasper): Find a way to listen for network closing.
class SystemInterface_ extends Interface:
  network_/NetworkResource? := ?
  constructor .network_:

  resolve host/string -> List:
    if not network_: throw "Network closed"
    return [dns.dns_lookup host]

  udp_open --port/int?=null -> udp.Socket:
    if not network_: throw "Network closed"
    return Socket "0.0.0.0" (port ? port : 0)

  tcp_connect address/SocketAddress -> tcp.Socket:
    if not network_: throw "Network closed"
    result := TcpSocket
    result.connect address.ip.stringify address.port
    return result

  tcp_listen port/int -> tcp.ServerSocket:
    if not network_: throw "Network closed"
    result := TcpServerSocket
    result.listen "0.0.0.0" port
    return result

  address -> IpAddress:
    if not network_: throw "Network closed"
    return network_.address

  close -> none:
    if not network_: return
    network_.close
    network_ = null
