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
  static SOCKET_OPTION_UDP_BROADCAST /int ::= 0
  static SOCKET_OPTION_TCP_NO_DELAY  /int ::= 100

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
  socket_get_option handle/int option/int -> any

  static SOCKET_SET_OPTION_INDEX /int ::= 301
  socket_set_option handle/int option/int value/any -> none

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

  socket_get_option handle/int option/int -> any:
    return invoke_ NetworkService.SOCKET_GET_OPTION_INDEX [handle, option]

  socket_set_option handle/int option/int value/any -> none:
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

/**
The $ProxyingNetworkServiceDefinition makes it easy to proxy a network
  interface and expose it as a provided service. The service can then
  be used across process boundaries, which makes it possible to run
  network drivers separate from the rest of the system.
*/
abstract class ProxyingNetworkServiceDefinition extends ServiceDefinition:
  network_/net.Interface ::= ?

  constructor name/string .network_ --major/int --minor/int --patch/int=0:
    super name --major=major --minor=minor --patch=patch

  /**
  This service definition decides which groups of service methods should be
    proxied when a client connects. The service might ask clients to proxy
    all TCP-related calls through the service, but let them take care of DNS
    resolution on their own.

  See the description of the proxy mask in the $NetworkService interface.
  */
  abstract proxy_mask -> int

  handle pid/int client/int index/int arguments/any -> any:
    if index == NetworkService.SOCKET_READ_INDEX:
      socket ::= convert_to_socket_ client arguments
      return socket.read
    if index == NetworkService.SOCKET_WRITE_INDEX:
      socket ::= convert_to_socket_ client arguments[0]
      return socket.write arguments[1]
    if index == NetworkService.UDP_RECEIVE_INDEX:
      socket ::= convert_to_socket_ client arguments
      datagram ::= socket.receive
      address ::= datagram.address
      return [datagram.data, address.ip.to_byte_array, address.port]
    if index == NetworkService.UDP_SEND_INDEX:
      socket ::= convert_to_socket_ client arguments[0]
      datagram ::= udp.Datagram arguments[1] (convert_to_socket_address_ arguments 2)
      return socket.send datagram

    if index == NetworkService.CONNECT_INDEX:
      return connect client
    if index == NetworkService.ADDRESS_INDEX:
      return address (resource client arguments)
    if index == NetworkService.RESOLVE_INDEX:
      return resolve (resource client arguments[0]) arguments[1]

    if index == NetworkService.UDP_OPEN_INDEX:
      return udp_open client arguments[1]
    if index == NetworkService.UDP_CONNECT_INDEX:
      socket ::= convert_to_socket_ client arguments[0]
      return socket.connect (convert_to_socket_address_ arguments 1)

    if index == NetworkService.TCP_CONNECT_INDEX:
      return tcp_connect client arguments[1] arguments[2]
    if index == NetworkService.TCP_LISTEN_INDEX:
      return tcp_listen client arguments[1]
    if index == NetworkService.TCP_ACCEPT_INDEX:
      socket ::= convert_to_socket_ client arguments
      return ProxyingSocketResource_ this client socket.accept
    if index == NetworkService.TCP_CLOSE_WRITE_INDEX:
      socket ::= convert_to_socket_ client arguments
      return socket.close_write

    if index == NetworkService.SOCKET_LOCAL_ADDRESS_INDEX:
      socket ::= convert_to_socket_ client arguments
      address ::= socket.local_address
      return [address.ip.to_byte_array, address.port]
    if index == NetworkService.SOCKET_PEER_ADDRESS_INDEX:
      socket ::= convert_to_socket_ client arguments
      address ::= socket.peer_address
      return [address.ip.to_byte_array, address.port]
    if index == NetworkService.SOCKET_MTU_INDEX:
      socket ::= convert_to_socket_ client arguments
      return socket.mtu
    if index == NetworkService.SOCKET_GET_OPTION_INDEX:
      socket ::= convert_to_socket_ client arguments[0]
      option ::= arguments[1]
      if option == NetworkService.SOCKET_OPTION_UDP_BROADCAST:
        return socket.broadcast
      if option == NetworkService.SOCKET_OPTION_TCP_NO_DELAY:
        return socket.no_delay
    if index == NetworkService.SOCKET_SET_OPTION_INDEX:
      socket ::= convert_to_socket_ client arguments[0]
      option ::= arguments[1]
      value ::= arguments[2]
      if option == NetworkService.SOCKET_OPTION_UDP_BROADCAST:
        return socket.broadcast = value
      if option == NetworkService.SOCKET_OPTION_TCP_NO_DELAY:
        return socket.no_delay = value
    unreachable

  convert_to_socket_ client/int handle/int -> any: /* udp.Socket | tcp.Socket | tcp.ServerSocket */
    resource ::= (resource client handle) as ProxyingSocketResource_
    return resource.socket

  connect client/int -> List:
    resource := ProxyingNetworkResource_ this client
    return [resource.serialize_for_rpc, proxy_mask]

  address resource/ServiceResource -> ByteArray:
    return network_.address.to_byte_array

  resolve resource/ServiceResource host/string -> List:
    results ::= network_.resolve host
    return results.map: it.to_byte_array

  udp_open client/int port/int? -> ServiceResource:
    socket ::= network_.udp_open --port=port
    return ProxyingSocketResource_ this client socket

  tcp_connect client/int ip/ByteArray port/int -> ServiceResource:
    socket ::= network_.tcp_connect (net.IpAddress ip).stringify port
    return ProxyingSocketResource_ this client socket

  tcp_listen client/int port/int -> ServiceResource:
    socket ::= network_.tcp_listen port
    return ProxyingSocketResource_ this client socket

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
    client ::= client_ as NetworkServiceClient
    return convert_to_socket_address_ (client.socket_local_address handle_)

  peer_address -> net.SocketAddress:
    client ::= client_ as NetworkServiceClient
    return convert_to_socket_address_ (client.socket_peer_address handle_)

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
    client ::= client_ as NetworkServiceClient
    client.udp_send handle_ datagram.data address.ip.to_byte_array address.port

  connect address/net.SocketAddress -> none:
    client ::= client_ as NetworkServiceClient
    client.udp_connect handle_ address.ip.to_byte_array address.port

  broadcast -> bool:
    client ::= client_ as NetworkServiceClient
    return client.socket_get_option handle_ NetworkService.SOCKET_OPTION_UDP_BROADCAST

  broadcast= value/bool:
    client ::= client_ as NetworkServiceClient
    client.socket_set_option handle_ NetworkService.SOCKET_OPTION_UDP_BROADCAST value

class TcpSocketResourceProxy_ extends SocketResourceProxy_ implements tcp.Socket:
  constructor client/NetworkServiceClient handle/int:
    super client handle

  // TODO(kasper): Remove this.
  set_no_delay enabled/bool -> none:
    no_delay = enabled

  no_delay -> bool:
    client ::= client_ as NetworkServiceClient
    return client.socket_get_option handle_ NetworkService.SOCKET_OPTION_TCP_NO_DELAY

  no_delay= value/bool -> none:
    client ::= client_ as NetworkServiceClient
    client.socket_set_option handle_ NetworkService.SOCKET_OPTION_TCP_NO_DELAY value

class TcpServerSocketResourceProxy_ extends ServiceResourceProxy implements tcp.ServerSocket:
  constructor client/NetworkServiceClient handle/int:
    super client handle

  local_address -> net.SocketAddress:
    client ::= client_ as NetworkServiceClient
    return convert_to_socket_address_ (client.socket_local_address handle_)

  accept -> tcp.Socket?:
    client ::= client_ as NetworkServiceClient
    socket ::= client.tcp_accept handle_
    return TcpSocketResourceProxy_ client socket

class ProxyingNetworkResource_ extends ServiceResource:
  constructor service/ServiceDefinition client/int:
    super service client
  on_closed -> none:
    // Do nothing.

class ProxyingSocketResource_ extends ServiceResource:
  socket/any ::= ?
  constructor service/ServiceDefinition client/int .socket:
    super service client
  on_closed -> none:
    socket.close
