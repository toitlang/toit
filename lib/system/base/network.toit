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
    ServiceHandler
    ServiceProvider
    ServiceResource
    ServiceResourceProxy

class NetworkResourceProxy extends ServiceResourceProxy:
  on-closed_/Lambda? := null

  constructor client/NetworkServiceClient handle/int:
    super client handle

  address -> net.IpAddress:
    return net.IpAddress
        (client_ as NetworkServiceClient).address handle_

  resolve host/string -> List:
    results := (client_ as NetworkServiceClient).resolve handle_ host
    return results.map: net.IpAddress it

  udp-open --port/int?=null -> udp.Socket:
    client ::= client_ as NetworkServiceClient
    socket ::= client.udp-open handle_ port
    return UdpSocketResourceProxy_ client socket

  tcp-connect address/net.SocketAddress -> tcp.Socket:
    client ::= client_ as NetworkServiceClient
    socket ::= client.tcp-connect handle_ address.ip.to-byte-array address.port
    return TcpSocketResourceProxy_ client socket

  tcp-listen port/int -> tcp.ServerSocket:
    client ::= client_ as NetworkServiceClient
    socket ::= client.tcp-listen handle_ port
    return TcpServerSocketResourceProxy_ client socket

  on-closed lambda/Lambda? -> none:
    if not lambda:
      on-closed_ = null
      return
    if on-closed_: throw "ALREADY_IN_USE"
    if is-closed: lambda.call
    else: on-closed_ = lambda

  close-handle_ -> int?:
    on-closed := on-closed_
    on-closed_ = null
    try:
      return super
    finally:
      if on-closed: on-closed.call

// ----------------------------------------------------------------------------

interface NetworkModule:
  connect -> none
  disconnect -> none

class NetworkResource extends ServiceResource:
  state_/NetworkState ::= ?
  constructor provider/ServiceProvider client/int .state_ --notifiable/bool=false:
    super provider client --notifiable=notifiable
  on-closed -> none:
    critical-do: state_.down

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
    finally: | is-exception exception |
      if is-exception:
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
The $CloseableNetwork is a convenience base class for implementing
  closeable networks that keep track of a single listener for the
  on-closed events.

Subclasses must take care to provide an implementation of the $close_
  method instead of overriding the $close method.

If the language supported mixins, the $CloseableNetwork could be
  mixed into $NetworkResourceProxy.
*/
abstract class CloseableNetwork:
  on-closed_/Lambda? := null

  abstract is-closed -> bool
  abstract close_ -> none

  on-closed lambda/Lambda? -> none:
    if not lambda:
      on-closed_ = null
      return
    if on-closed_: throw "ALREADY_IN_USE"
    if is-closed: lambda.call
    else: on-closed_ = lambda

  close -> none:
    on-closed := on-closed_
    on-closed_ = null
    try:
      close_
    finally:
      if on-closed: on-closed.call

// ----------------------------------------------------------------------------

/**
The $ProxyingNetworkServiceProvider makes it easy to proxy a network
  interface and expose it as a provided service. The service can then
  be used across process boundaries, which makes it possible to run
  network drivers separate from the rest of the system.
*/
abstract class ProxyingNetworkServiceProvider extends ServiceProvider
    implements NetworkModule ServiceHandler:
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
  abstract proxy-mask -> int

  /**
  Opens the proxied network.

  Subclasses may decide to use the call to establish the underlying
    connection in which case the call may throw exceptions and
    possibly time out. In case of such exceptions, $close-network
    is not called.
  */
  abstract open-network -> net.Interface

  /**
  Closes the proxied network.
  */
  abstract close-network network/net.Interface -> none

  /**
  Requests quarantining the network identified by $name.

  Subclasses may override and act on the request.
  */
  quarantine name/string -> none:
    // Do nothing.

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == NetworkService.SOCKET-READ-INDEX:
      socket ::= convert-to-socket_ client arguments
      return socket.read
    if index == NetworkService.SOCKET-WRITE-INDEX:
      socket ::= convert-to-socket_ client arguments[0]
      return socket.write arguments[1]
    if index == NetworkService.UDP-RECEIVE-INDEX:
      socket ::= convert-to-socket_ client arguments
      datagram ::= socket.receive
      address ::= datagram.address
      return [datagram.data, address.ip.to-byte-array, address.port]
    if index == NetworkService.UDP-SEND-INDEX:
      socket ::= convert-to-socket_ client arguments[0]
      datagram ::= udp.Datagram arguments[1] (convert-to-socket-address_ arguments 2)
      return socket.send datagram

    if index == NetworkService.CONNECT-INDEX:
      return connect client
    if index == NetworkService.ADDRESS-INDEX:
      return address (resource client arguments)
    if index == NetworkService.RESOLVE-INDEX:
      return resolve (resource client arguments[0]) arguments[1]
    if index == NetworkService.QUARANTINE-INDEX:
      return quarantine arguments

    if index == NetworkService.UDP-OPEN-INDEX:
      return udp-open client arguments[1]
    if index == NetworkService.UDP-CONNECT-INDEX:
      socket ::= convert-to-socket_ client arguments[0]
      return socket.connect (convert-to-socket-address_ arguments 1)

    if index == NetworkService.TCP-CONNECT-INDEX:
      return tcp-connect client arguments[1] arguments[2]
    if index == NetworkService.TCP-LISTEN-INDEX:
      return tcp-listen client arguments[1]
    if index == NetworkService.TCP-ACCEPT-INDEX:
      socket ::= convert-to-socket_ client arguments
      return ProxyingSocketResource_ this client socket.accept
    if index == NetworkService.TCP-CLOSE-WRITE-INDEX:
      socket ::= convert-to-socket_ client arguments
      return socket.close-write

    if index == NetworkService.SOCKET-LOCAL-ADDRESS-INDEX:
      socket ::= convert-to-socket_ client arguments
      address ::= socket.local-address
      return [address.ip.to-byte-array, address.port]
    if index == NetworkService.SOCKET-PEER-ADDRESS-INDEX:
      socket ::= convert-to-socket_ client arguments
      address ::= socket.peer-address
      return [address.ip.to-byte-array, address.port]
    if index == NetworkService.SOCKET-MTU-INDEX:
      socket ::= convert-to-socket_ client arguments
      return socket.mtu
    if index == NetworkService.SOCKET-GET-OPTION-INDEX:
      socket ::= convert-to-socket_ client arguments[0]
      option ::= arguments[1]
      if option == NetworkService.SOCKET-OPTION-UDP-BROADCAST:
        return socket.broadcast
      if option == NetworkService.SOCKET-OPTION-TCP-NO-DELAY:
        return socket.no-delay
    if index == NetworkService.SOCKET-SET-OPTION-INDEX:
      socket ::= convert-to-socket_ client arguments[0]
      option ::= arguments[1]
      value ::= arguments[2]
      if option == NetworkService.SOCKET-OPTION-UDP-BROADCAST:
        return socket.broadcast = value
      if option == NetworkService.SOCKET-OPTION-TCP-NO-DELAY:
        return socket.no-delay = value
    unreachable

  convert-to-socket_ client/int handle/int -> any: /* udp.Socket | tcp.Socket | tcp.ServerSocket */
    resource ::= (resource client handle) as ProxyingSocketResource_
    return resource.socket

  connect client/int -> List:
    // We use 'this' service definition as the network module, so we get told
    // when the module disconnects as a result of calling $NetworkState.down.
    state_.up: this
    resource := NetworkResource this client state_ --notifiable
    return [
      resource.serialize-for-rpc,
      proxy-mask | NetworkService.PROXY-QUARANTINE,
      network_.name
    ]

  connect -> none:
    network := open-network
    network.on-closed:: disconnect
    network_ = network

  disconnect -> none:
    network := network_
    if not network: return
    network_ = null
    try:
      close-network network
    finally:
      critical-do:
        resources-do: | resource/ServiceResource |
          if resource is NetworkResource and not resource.is-closed:
            resource.notify_ NetworkService.NOTIFY-CLOSED --close

  address resource/ServiceResource -> ByteArray:
    return network_.address.to-byte-array

  resolve resource/ServiceResource host/string -> List:
    results ::= network_.resolve host
    return results.map: it.to-byte-array

  udp-open client/int port/int? -> ServiceResource:
    socket ::= network_.udp-open --port=port
    return ProxyingSocketResource_ this client socket

  tcp-connect client/int ip/ByteArray port/int -> ServiceResource:
    socket ::= network_.tcp-connect (net.IpAddress ip).stringify port
    return ProxyingSocketResource_ this client socket

  tcp-listen client/int port/int -> ServiceResource:
    socket ::= network_.tcp-listen port
    return ProxyingSocketResource_ this client socket

// ----------------------------------------------------------------------------

convert-to-socket-address_ address/List offset/int=0 -> net.SocketAddress:
  ip ::= net.IpAddress address[offset]
  port ::= address[offset + 1]
  return net.SocketAddress ip port

class SocketResourceProxy_ extends ServiceResourceProxy:
  static WRITE-DATA-SIZE-MAX_ /int ::= 2048

  constructor client/NetworkServiceClient handle/int:
    super client handle

  local-address -> net.SocketAddress:
    client ::= client_ as NetworkServiceClient
    return convert-to-socket-address_ (client.socket-local-address handle_)

  peer-address -> net.SocketAddress:
    client ::= client_ as NetworkServiceClient
    return convert-to-socket-address_ (client.socket-peer-address handle_)

  read -> ByteArray?:
    return (client_ as NetworkServiceClient).socket-read handle_

  write data from=0 to=data.size -> int:
    to = min to (from + WRITE-DATA-SIZE-MAX_)
    return (client_ as NetworkServiceClient).socket-write handle_ data[from..to]

  mtu -> int:
    return (client_ as NetworkServiceClient).socket-mtu handle_

  close-write:
    return (client_ as NetworkServiceClient).tcp-close-write handle_

class UdpSocketResourceProxy_ extends SocketResourceProxy_ implements udp.Socket:
  constructor client/NetworkServiceClient handle/int:
    super client handle

  receive -> udp.Datagram:
    result ::= (client_ as NetworkServiceClient).udp-receive handle_
    return udp.Datagram result[0] (convert-to-socket-address_ result 1)

  send datagram/udp.Datagram -> none:
    address ::= datagram.address
    client ::= client_ as NetworkServiceClient
    client.udp-send handle_ datagram.data address.ip.to-byte-array address.port

  connect address/net.SocketAddress -> none:
    client ::= client_ as NetworkServiceClient
    client.udp-connect handle_ address.ip.to-byte-array address.port

  broadcast -> bool:
    client ::= client_ as NetworkServiceClient
    return client.socket-get-option handle_ NetworkService.SOCKET-OPTION-UDP-BROADCAST

  broadcast= value/bool:
    client ::= client_ as NetworkServiceClient
    client.socket-set-option handle_ NetworkService.SOCKET-OPTION-UDP-BROADCAST value

class TcpSocketResourceProxy_ extends SocketResourceProxy_ implements tcp.Socket:
  constructor client/NetworkServiceClient handle/int:
    super client handle

  // TODO(kasper): Remove this.
  set-no-delay enabled/bool -> none:
    no-delay = enabled

  no-delay -> bool:
    client ::= client_ as NetworkServiceClient
    return client.socket-get-option handle_ NetworkService.SOCKET-OPTION-TCP-NO-DELAY

  no-delay= value/bool -> none:
    client ::= client_ as NetworkServiceClient
    client.socket-set-option handle_ NetworkService.SOCKET-OPTION-TCP-NO-DELAY value

class TcpServerSocketResourceProxy_ extends ServiceResourceProxy implements tcp.ServerSocket:
  constructor client/NetworkServiceClient handle/int:
    super client handle

  local-address -> net.SocketAddress:
    client ::= client_ as NetworkServiceClient
    return convert-to-socket-address_ (client.socket-local-address handle_)

  accept -> tcp.Socket?:
    client ::= client_ as NetworkServiceClient
    socket ::= client.tcp-accept handle_
    return TcpSocketResourceProxy_ client socket

class ProxyingSocketResource_ extends ServiceResource:
  socket/any ::= ?
  constructor provider/ServiceProvider client/int .socket:
    super provider client
  on-closed -> none:
    socket.close
