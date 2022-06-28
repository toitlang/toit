// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import net.udp
import net.tcp

import system.api.network
  show
    NetworkService
    NetworkServiceClient

import system.services
  show
    ServiceClient
    ServiceDefinition
    ServiceResource
    ServiceResourceProxy

class NetworkResourceProxy extends ServiceResourceProxy:
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

// ----------------------------------------------------------------------------

interface NetworkModule:
  connect -> none
  disconnect -> none

class NetworkResource extends ServiceResource:
  state_/NetworkState ::= ?
  constructor service/ServiceDefinition client/int .state_ --notifiable/bool=false:
    super service client --notifiable=notifiable
  on_closed -> none:
    critical_do: state_.down

/**
The $NetworkState monitor handles tracking the usage of a $NetworkModule. The
  $up method is used to signal that a client needs to use the module and the
  $down method is used to signal that it is no longer needed.

Multiple clients can request access to the $NetworkModule simultaneously,
  so the accesses need to be synchronized through the monitor operations.
*/
monitor NetworkState:
  module_/NetworkModule? := null
  usage_/int := 0

  module -> NetworkModule?:
    return module_

  up [create] -> NetworkModule:
    usage_++
    if module_: return module_
    module/NetworkModule? := null
    try:
      module = create.call
      module.connect
      module_ = module
      return module
    finally: | is_exception exception |
      if is_exception:
        // Do not count the usage if we didn't manage
        // to produce a working module.
        usage_--
        // Disconnect the module if it was created, but connecting
        // failed with an exception.
        if module: module.disconnect

  down -> none:
    usage_--
    if usage_ > 0 or not module_: return
    try:
      module_.disconnect
    finally:
      // Assume the module is off even if turning
      // it off threw an exception.
      module_ = null

// ----------------------------------------------------------------------------

/**
The $ProxyingNetworkServiceDefinition makes it easy to proxy a network
  interface and expose it as a provided service. The service can then
  be used across process boundaries, which makes it possible to run
  network drivers separate from the rest of the system.
*/
abstract class ProxyingNetworkServiceDefinition extends ServiceDefinition implements NetworkModule:
  state_/NetworkState ::= NetworkState
  network_/net.Interface? := null

  constructor name/string --major/int --minor/int --patch/int=0:
    super name --major=major --minor=minor --patch=patch

  /**
  This service definition decides which groups of service methods should be
    proxied when a client connects. The service might ask clients to proxy
    all TCP-related calls through the service, but let them take care of DNS
    resolution on their own.

  See the description of the proxy mask in the $NetworkService interface.
  */
  abstract proxy_mask -> int

  /**
  Opens the proxied network.

  Subclasses may decide to use the call to establish the underlying
    connection in which case the call may throw exceptions and
    possibly time out. In case of such exceptions, $close_network
    is not called.
  */
  abstract open_network -> net.Interface

  /**
  Closes the proxied network.
  */
  abstract close_network network/net.Interface -> none

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
    // We use 'this' service definition as the network module, so we get told
    // when the module disconnects as a result of calling $NetworkState.down.
    state_.up: this
    resource := NetworkResource this client state_
    return [resource.serialize_for_rpc, proxy_mask]

  connect -> none:
    network_ = open_network

  disconnect -> none:
    if not network_: return
    close_network network_
    network_ = null

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

class ProxyingSocketResource_ extends ServiceResource:
  socket/any ::= ?
  constructor service/ServiceDefinition client/int .socket:
    super service client
  on_closed -> none:
    socket.close
