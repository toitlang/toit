// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import net.udp
import net.tcp

import system.services
  show
    ServiceClient
    ServiceDefinition
    ServiceResource
    ServiceResourceProxy

interface NetworkService:
  static UUID  /string ::= "063e228a-3a7a-44a8-b024-d55127255ccb"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 3

  /**
  Proxy mask bits that indicate which operations must be proxied
    through the service. See $connect.
  */
  static PROXY_NONE    /int ::= 0
  static PROXY_ADDRESS /int ::= 1 << 0
  static PROXY_RESOLVE /int ::= 1 << 1
  static PROXY_UDP     /int ::= 1 << 2
  static PROXY_TCP     /int ::= 1 << 3

  /**
  The socket options can be read or written using $socket_get_option
    and $socket_set_option.
  */
  static SOCKET_OPTION_UDP_BROADCAST /string ::= "udp-broadcast"
  static SOCKET_OPTION_TCP_NO_DELAY  /string ::= "tcp-no-delay"

  // The connect call returns a handle to the network resource and
  // the proxy mask bits in a list. The proxy mask bits indicate
  // which operations the service definition wants the client to
  // proxy through it.
  static CONNECT_INDEX /int ::= 0
  connect -> List

  static ADDRESS_INDEX /int ::= 1
  address handle/int -> ByteArray

  static RESOLVE_INDEX /int ::= 2
  resolve handle/int host/string -> List

  static UDP_OPEN_INDEX /int ::= 100
  udp_open handle/int port/int? -> int

  static UDP_CONNECT_INDEX /int ::= 101
  udp_connect handle/int ip/ByteArray port/int -> none

  static UDP_RECEIVE_INDEX /int ::= 102
  udp_receive handle/int -> List

  static UDP_SEND_INDEX /int ::= 103
  udp_send handle/int data/ByteArray ip/ByteArray port/int -> none

  static TCP_CONNECT_INDEX /int ::= 200
  tcp_connect handle/int ip/ByteArray port/int -> int

  static TCP_LISTEN_INDEX /int ::= 201
  tcp_listen handle/int port/int -> int

  static TCP_ACCEPT_INDEX /int ::= 202
  tcp_accept handle/int -> int

  static TCP_CLOSE_WRITE_INDEX /int ::= 203
  tcp_close_write handle/int -> none

  static SOCKET_GET_OPTION_INDEX /int ::= 300
  socket_get_option handle/int option/string -> any

  static SOCKET_SET_OPTION_INDEX /int ::= 301
  socket_set_option handle/int option/string value/any -> none

  static SOCKET_LOCAL_ADDRESS_INDEX /int ::= 302
  socket_local_address handle/int -> List

  static SOCKET_PEER_ADDRESS_INDEX /int ::= 303
  socket_peer_address handle/int -> List

  static SOCKET_READ_INDEX /int ::= 304
  socket_read handle/int -> ByteArray?

  static SOCKET_WRITE_INDEX /int ::= 305
  socket_write handle/int data -> int

  static SOCKET_MTU_INDEX /int ::= 306
  socket_mtu handle/int -> int

class NetworkServiceClient extends ServiceClient implements NetworkService:
  constructor --open/bool=true:
    super --open=open

  open -> NetworkServiceClient?:
    return (open_ NetworkService.UUID NetworkService.MAJOR NetworkService.MINOR) and this

  connect -> List:
    return invoke_ NetworkService.CONNECT_INDEX null

  address handle/int -> ByteArray:
    return invoke_ NetworkService.ADDRESS_INDEX handle

  resolve handle/int host/string -> List:
    return invoke_ NetworkService.RESOLVE_INDEX [handle, host]

  udp_open handle/int port/int? -> int:
    return invoke_ NetworkService.UDP_OPEN_INDEX [handle, port]

  udp_connect handle/int ip/ByteArray port/int -> none:
    invoke_ NetworkService.UDP_CONNECT_INDEX [handle, ip, port]

  udp_receive handle/int -> List:
    return invoke_ NetworkService.UDP_RECEIVE_INDEX handle

  udp_send handle/int data/ByteArray ip/ByteArray port/int -> none:
    invoke_ NetworkService.UDP_SEND_INDEX [handle, data, ip, port]

  tcp_connect handle/int ip/ByteArray port/int -> int:
    return invoke_ NetworkService.TCP_CONNECT_INDEX [handle, ip, port]

  tcp_listen handle/int port/int -> int:
    return invoke_ NetworkService.TCP_LISTEN_INDEX [handle, port]

  tcp_accept handle/int -> int:
    return invoke_ NetworkService.TCP_ACCEPT_INDEX handle

  tcp_close_write handle/int -> none:
    invoke_ NetworkService.TCP_CLOSE_WRITE_INDEX handle

  socket_get_option handle/int option/string -> any:
    return invoke_ NetworkService.SOCKET_GET_OPTION_INDEX [handle, option]

  socket_set_option handle/int option/string value/any -> none:
    invoke_ NetworkService.SOCKET_SET_OPTION_INDEX [handle, option, value]

  socket_local_address handle/int -> List:
    return invoke_ NetworkService.SOCKET_LOCAL_ADDRESS_INDEX handle

  socket_peer_address handle/int -> List:
    return invoke_ NetworkService.SOCKET_PEER_ADDRESS_INDEX handle

  socket_read handle/int -> ByteArray?:
    return invoke_ NetworkService.SOCKET_READ_INDEX handle

  socket_write handle/int data:
    return invoke_ NetworkService.SOCKET_WRITE_INDEX [handle, data]

  socket_mtu handle/int -> int:
    return invoke_ NetworkService.SOCKET_MTU_INDEX handle

class NetworkResource extends ServiceResourceProxy:
  constructor client/NetworkServiceClient handle/int:
    super client handle

  address -> net.IpAddress:
    return net.IpAddress
        (client_ as NetworkServiceClient).address handle_

  resolve host/string -> List:
    results := (client_ as NetworkServiceClient).resolve handle_ host
    return results.map: net.IpAddress it

  udp_open --port/int?=null -> udp.Socket:
    client ::= client_ as NetworkServiceClient
    socket ::= client.udp_open handle_ port
    return UdpSocketResourceProxy_ client socket

  tcp_connect address/net.SocketAddress -> tcp.Socket:
    client ::= client_ as NetworkServiceClient
    socket ::= client.tcp_connect handle_ address.ip.to_byte_array address.port
    return TcpSocketResourceProxy_ client socket

  tcp_listen port/int -> tcp.ServerSocket:
    client ::= client_ as NetworkServiceClient
    socket ::= client.tcp_listen handle_ port
    return TcpServerSocketResourceProxy_ client socket

abstract class SocketResource extends ServiceResource:
  constructor service/ServiceDefinition client/int:
    super service client

  static handle service/ServiceDefinition client/int index/int arguments/any [reply] -> none:
    if index == NetworkService.SOCKET_GET_OPTION_INDEX:
      // Unimplemented for now: socket_get_option handle/int option/string -> any
      unreachable
    if index == NetworkService.SOCKET_SET_OPTION_INDEX:
      // Unimplemented for now: socket_set_option handle/int option/string value/any -> none
      unreachable
    if index == NetworkService.SOCKET_LOCAL_ADDRESS_INDEX:
      resource ::= (service.resource client arguments) as SocketResource
      address ::= resource.local_address
      reply.call [address.ip.to_byte_array, address.port]
    if index == NetworkService.SOCKET_PEER_ADDRESS_INDEX:
      resource ::= (service.resource client arguments) as SocketResource
      address ::= resource.peer_address
      reply.call [address.ip.to_byte_array, address.port]
    if index == NetworkService.SOCKET_READ_INDEX:
      resource ::= (service.resource client arguments) as SocketResource
      reply.call resource.read
    if index == NetworkService.SOCKET_WRITE_INDEX:
      resource ::= (service.resource client arguments[0]) as SocketResource
      reply.call (resource.write arguments[1])
    if index == NetworkService.SOCKET_MTU_INDEX:
      resource ::= (service.resource client arguments) as SocketResource
      reply.call resource.mtu
    return  // Unhandled invocation.

  abstract local_address -> net.SocketAddress
  abstract peer_address -> net.SocketAddress
  abstract read -> ByteArray?
  abstract write data -> int
  abstract mtu -> int

class UdpSocketResource extends SocketResource:
  socket_/udp.Socket ::= ?

  constructor service/ServiceDefinition client/int .socket_:
    super service client

  static handle service/ServiceDefinition client/int index/int arguments/any [reply] -> none:
    if index == NetworkService.UDP_CONNECT_INDEX:
      resource ::= (service.resource client arguments[0]) as UdpSocketResource
      socket ::= resource.socket_
      reply.call (socket.connect (convert_to_socket_address_ arguments 1))
    if index == NetworkService.UDP_RECEIVE_INDEX:
      resource ::= (service.resource client arguments) as UdpSocketResource
      socket ::= resource.socket_
      datagram ::= socket.receive
      address ::= datagram.address
      reply.call [datagram.data, address.ip.to_byte_array, address.port]
    if index == NetworkService.UDP_SEND_INDEX:
      resource ::= (service.resource client arguments[0]) as UdpSocketResource
      socket ::= resource.socket_
      datagram ::= udp.Datagram arguments[1] (convert_to_socket_address_ arguments 2)
      reply.call (socket.send datagram)
    return  // Unhandled invocation.

  local_address -> net.SocketAddress: return socket_.local_address
  peer_address -> net.SocketAddress: unreachable
  read -> ByteArray?: return socket_.read
  write data -> int: return socket_.write data
  mtu -> int: return socket_.mtu
  on_closed -> none: socket_.close

class TcpSocketResource extends SocketResource:
  socket_/tcp.Socket ::= ?

  constructor service/ServiceDefinition client/int .socket_:
    super service client

  static handle service/ServiceDefinition client/int index/int arguments/any [reply] -> none:
    if index == NetworkService.TCP_CLOSE_WRITE_INDEX:
      resource ::= (service.resource client arguments) as TcpSocketResource
      socket ::= resource.socket_
      reply.call socket.close_write
    return  // Unhandled invocation.

  local_address -> net.SocketAddress: return socket_.local_address
  peer_address -> net.SocketAddress: return socket_.peer_address
  read -> ByteArray?: return socket_.read
  write data -> int: return socket_.write data
  mtu -> int: return socket_.mtu
  on_closed -> none: socket_.close

class TcpServerSocketResource extends ServiceResource:
  socket_/tcp.ServerSocket ::= ?

  constructor service/ServiceDefinition client/int .socket_:
    super service client

  static handle service/ServiceDefinition client/int index/int arguments/any [reply] -> none:
    if index == NetworkService.TCP_ACCEPT_INDEX:
      resource ::= (service.resource client arguments) as TcpServerSocketResource
      socket ::= resource.socket_
      reply.call (TcpSocketResource service client socket.accept)
    return  // Unhandled invocation.

  on_closed -> none: socket_.close

// ----------------------------------------------------------------------------

convert_to_socket_address_ address/List offset/int=0 -> net.SocketAddress:
  ip ::= net.IpAddress address[offset]
  port ::= address[offset + 1]
  return net.SocketAddress ip port

class SocketResourceProxy_ extends ServiceResourceProxy:
  static WRITE_DATA_SIZE_MAX_ /int ::= 2048

  constructor client/NetworkServiceClient handle/int:
    super client handle

  local_address -> net.SocketAddress:
    return convert_to_socket_address_
        (client_ as NetworkServiceClient).socket_local_address handle_

  peer_address -> net.SocketAddress:
    return convert_to_socket_address_
        (client_ as NetworkServiceClient).socket_peer_address handle_

  read -> ByteArray?:
    return (client_ as NetworkServiceClient).socket_read handle_

  write data from=0 to=data.size -> int:
    to = min to (from + WRITE_DATA_SIZE_MAX_)
    return (client_ as NetworkServiceClient).socket_write handle_ data[from..to]

  mtu -> int:
    return (client_ as NetworkServiceClient).socket_mtu handle_

  close_write:
    return (client_ as NetworkServiceClient).tcp_close_write handle_

class UdpSocketResourceProxy_ extends SocketResourceProxy_ implements udp.Socket:
  constructor client/NetworkServiceClient handle/int:
    super client handle

  receive -> udp.Datagram:
    result ::= (client_ as NetworkServiceClient).udp_receive handle_
    return udp.Datagram result[0] (convert_to_socket_address_ result 1)

  send datagram/udp.Datagram -> none:
    address ::= datagram.address
    (client_ as NetworkServiceClient).udp_send
        handle_
        datagram.data
        address.ip.to_byte_array
        address.port

  connect address/net.SocketAddress -> none:
    (client_ as NetworkServiceClient).udp_connect
        handle_
        address.ip.to_byte_array
        address.port

  broadcast -> bool:
    return (client_ as NetworkServiceClient).socket_get_option
        handle_
        NetworkService.SOCKET_OPTION_UDP_BROADCAST

  broadcast= value/bool:
    (client_ as NetworkServiceClient).socket_set_option
        handle_
        NetworkService.SOCKET_OPTION_UDP_BROADCAST
        value

class TcpSocketResourceProxy_ extends SocketResourceProxy_ implements tcp.Socket:
  constructor client/NetworkServiceClient handle/int:
    super client handle

  // TODO(kasper): Remove this.
  set_no_delay enabled/bool -> none:
    no_delay = enabled

  no_delay -> bool:
    return (client_ as NetworkServiceClient).socket_get_option
        handle_
        NetworkService.SOCKET_OPTION_TCP_NO_DELAY

  no_delay= value/bool -> none:
    (client_ as NetworkServiceClient).socket_set_option
        handle_
        NetworkService.SOCKET_OPTION_TCP_NO_DELAY
        value

class TcpServerSocketResourceProxy_ extends ServiceResourceProxy implements tcp.ServerSocket:
  constructor client/NetworkServiceClient handle/int:
    super client handle

  local_address -> net.SocketAddress:
    return convert_to_socket_address_
        (client_ as NetworkServiceClient).socket_local_address handle_

  accept -> tcp.Socket?:
    client ::= client_ as NetworkServiceClient
    socket ::= client.tcp_accept handle_
    return TcpSocketResourceProxy_ client socket
