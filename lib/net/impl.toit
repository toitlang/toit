// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import rpc

import .net
import .tcp as tcp
import .udp as udp

RPC_NETWORK_OPEN ::= 500
RPC_NETWORK_DISCONNECT ::= 501
RPC_NETWORK_RESOLVE ::= 502
RPC_NETWORK_UDP_OPEN ::= 503
RPC_NETWORK_TCP_CONNECT ::= 504
RPC_NETWORK_TCP_LISTEN ::= 505
RPC_NETWORK_TCP_PEER_ADDRESS ::= 506
RPC_NETWORK_TCP_SET_NO_DELAY ::= 507
RPC_NETWORK_TCP_CLOSE_WRITE ::= 508
RPC_NETWORK_TCP_ACCEPT ::= 509
RPC_NETWORK_UDP_CONNECT ::= 510
RPC_NETWORK_UDP_RECEIVE ::= 511
RPC_NETWORK_UDP_SEND ::= 512
RPC_NETWORK_UDP_BROADCAST ::= 513
RPC_NETWORK_UDP_SET_BROADCAST ::= 514
RPC_NETWORK_SOCKET_WRITE ::= 515
RPC_NETWORK_SOCKET_READ ::= 516
RPC_NETWORK_SOCKET_LOCAL_ADDRESS ::= 517
RPC_NETWORK_SOCKET_CLOSE ::= 518
RPC_NETWORK_SOCKET_MTU ::= 519

open -> Interface:
  handle := rpc.invoke RPC_NETWORK_OPEN []
  return InterfaceImpl_ handle

class InterfaceImpl_ extends Interface:
  handle_ := ?

  constructor .handle_:

  resolve host/string -> List:
    addresses := rpc.invoke RPC_NETWORK_RESOLVE [handle_, host]
    return addresses.map: IpAddress it

  udp_open -> udp.Socket: return udp_open --port=null
  udp_open --port/int? -> udp.Socket:
    handle := rpc.invoke RPC_NETWORK_UDP_OPEN [handle_, port]
    return UdpSocketImpl_ handle

  tcp_connect address/SocketAddress -> tcp.Socket:
    handle := rpc.invoke RPC_NETWORK_TCP_CONNECT [handle_, address.to_byte_array]
    return TcpSocketImpl_ handle

  tcp_listen port/int -> tcp.ServerSocket:
    handle := rpc.invoke RPC_NETWORK_TCP_LISTEN [handle_, port]
    return TcpServerSocketImpl_ handle

class UdpSocketImpl_ implements udp.Socket:
  handle_ ::= ?

  constructor .handle_:

  local_address -> SocketAddress:
    return SocketAddress.deserialize
      rpc.invoke RPC_NETWORK_SOCKET_LOCAL_ADDRESS [handle_]

  receive -> udp.Datagram:
    return udp.Datagram.deserialize
      rpc.invoke RPC_NETWORK_UDP_RECEIVE [handle_]

  send datagram/udp.Datagram -> none:
    rpc.invoke RPC_NETWORK_UDP_SEND [handle_, datagram.to_byte_array]

  connect address/SocketAddress -> none:
    rpc.invoke RPC_NETWORK_UDP_CONNECT [handle_, address.to_byte_array]

  read -> ByteArray?:
    return rpc.invoke RPC_NETWORK_SOCKET_READ [handle_]

  write data from/int=0 to/int=data.size -> int:
    return rpc.invoke RPC_NETWORK_SOCKET_WRITE [handle_, copy_data_ data from to]

  close -> none:
    rpc.invoke RPC_NETWORK_SOCKET_CLOSE [handle_]

  mtu -> int:
    return rpc.invoke RPC_NETWORK_SOCKET_MTU [handle_]

  broadcast -> bool:
    return rpc.invoke RPC_NETWORK_UDP_BROADCAST [handle_]

  broadcast= value/bool:
    rpc.invoke RPC_NETWORK_UDP_SET_BROADCAST [handle_, value]

class TcpSocketImpl_ implements tcp.Socket:
  handle_ ::= ?

  constructor .handle_:

  local_address -> SocketAddress:
    return SocketAddress.deserialize
      rpc.invoke RPC_NETWORK_SOCKET_LOCAL_ADDRESS [handle_]

  peer_address -> SocketAddress:
    return SocketAddress.deserialize
      rpc.invoke RPC_NETWORK_TCP_PEER_ADDRESS [handle_]

  set_no_delay enabled/bool:
    return rpc.invoke RPC_NETWORK_TCP_SET_NO_DELAY [handle_, enabled]

  read -> ByteArray?:
    return rpc.invoke RPC_NETWORK_SOCKET_READ [handle_]

  write data from/int=0 to/int=data.size -> int:
    return rpc.invoke RPC_NETWORK_SOCKET_WRITE [handle_, copy_data_ data from to]

  close_write:
    return rpc.invoke RPC_NETWORK_TCP_CLOSE_WRITE [handle_]

  close:
    return rpc.invoke RPC_NETWORK_SOCKET_CLOSE [handle_]

  mtu:
    return rpc.invoke RPC_NETWORK_SOCKET_MTU [handle_]

class TcpServerSocketImpl_ implements tcp.ServerSocket:
  handle_ ::= ?

  constructor .handle_:

  local_address -> SocketAddress:
    return SocketAddress.deserialize
      rpc.invoke RPC_NETWORK_SOCKET_LOCAL_ADDRESS [handle_]

  close:
    return rpc.invoke RPC_NETWORK_SOCKET_CLOSE [handle_]

  accept -> tcp.Socket?:
    handle := rpc.invoke RPC_NETWORK_TCP_ACCEPT [handle_]
    if not handle: return null
    return TcpSocketImpl_ handle

// The socket write operations allow strings and byte arrays as the data. For now,
// we normalize them to byte arrays so the kernel implementation doesn't have to
// deal with strings. We generally do support strings in the associated primitive
// operations, so we could also keep them as is (type-wise). We will need to add
// tests for this behavior.
copy_data_ data from/int to/int -> ByteArray:
  if data is ByteArray: return data.copy from to
  if data is string: return data.to_byte_array from to
  throw "INVALID_ARGUMENT"
