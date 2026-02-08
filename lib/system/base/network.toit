// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import net
import net.udp
import net.tcp

import system.api.network
  show
    NetworkService

import system.services
  show
    ServiceClient
    ServiceHandler
    ServiceProvider
    ServiceResource
    ServiceResourceProxy
    ServiceSelector

abstract class NetworkServiceClientBase extends ServiceClient implements NetworkService:
  constructor selector/ServiceSelector:
    // Extended network APIs use their own specialized selectors, so $selector
    // may not match $NetworkService.SELECTOR here.
    super selector

  connect -> List:
    return invoke_ NetworkService.CONNECT-INDEX null

  address handle/int -> ByteArray:
    return invoke_ NetworkService.ADDRESS-INDEX handle

  resolve handle/int host/string -> List:
    return invoke_ NetworkService.RESOLVE-INDEX [handle, host]

  quarantine name/string -> none:
    invoke_ NetworkService.QUARANTINE-INDEX name

  udp-open handle/int port/int? -> int:
    return invoke_ NetworkService.UDP-OPEN-INDEX [handle, port]

  udp-open-multicast -> int
      handle/int
      address/ByteArray
      port/int
      if-addr/ByteArray?
      reuse-address/bool
      reuse-port/bool
      loopback/bool
      ttl/int:
    return invoke_ NetworkService.UDP-OPEN-MULTICAST-INDEX [
        handle,
        address,
        port,
        if-addr,
        reuse-address,
        reuse-port,
        loopback,
        ttl]


  udp-connect handle/int ip/ByteArray port/int -> none:
    invoke_ NetworkService.UDP-CONNECT-INDEX [handle, ip, port]

  udp-receive handle/int -> List:
    return invoke_ NetworkService.UDP-RECEIVE-INDEX handle

  udp-send handle/int data/ByteArray ip/ByteArray port/int -> none:
    invoke_ NetworkService.UDP-SEND-INDEX [handle, data, ip, port]

  tcp-connect handle/int ip/ByteArray port/int -> int:
    return invoke_ NetworkService.TCP-CONNECT-INDEX [handle, ip, port]

  tcp-listen handle/int port/int -> int:
    return invoke_ NetworkService.TCP-LISTEN-INDEX [handle, port]

  tcp-accept handle/int -> int:
    return invoke_ NetworkService.TCP-ACCEPT-INDEX handle

  tcp-close-write handle/int -> none:
    invoke_ NetworkService.TCP-CLOSE-WRITE-INDEX handle

  socket-get-option handle/int option/int -> any:
    return invoke_ NetworkService.SOCKET-GET-OPTION-INDEX [handle, option]

  socket-set-option handle/int option/int value/any -> none:
    invoke_ NetworkService.SOCKET-SET-OPTION-INDEX [handle, option, value]

  socket-local-address handle/int -> List:
    return invoke_ NetworkService.SOCKET-LOCAL-ADDRESS-INDEX handle

  socket-peer-address handle/int -> List:
    return invoke_ NetworkService.SOCKET-PEER-ADDRESS-INDEX handle

  socket-read handle/int -> ByteArray?:
    return invoke_ NetworkService.SOCKET-READ-INDEX handle

  socket-write handle/int data:
    return invoke_ NetworkService.SOCKET-WRITE-INDEX [handle, data]

  socket-mtu handle/int -> int:
    return invoke_ NetworkService.SOCKET-MTU-INDEX handle

class NetworkResourceProxy extends ServiceResourceProxy:
  on-closed_/Lambda? := null

  constructor client/NetworkServiceClientBase handle/int:
    super client handle

  address -> net.IpAddress:
    return net.IpAddress
        (client_ as NetworkServiceClientBase).address handle_

  resolve host/string -> List:
    results := (client_ as NetworkServiceClientBase).resolve handle_ host
    return results.map: net.IpAddress it

  udp-open --port/int?=null -> udp.Socket:
    client ::= client_ as NetworkServiceClientBase
    socket ::= client.udp-open handle_ port
    return UdpSocketResourceProxy_ client socket

  udp-open-multicast -> udp.MulticastSocket
      address/net.IpAddress
      port/int
      --if-addr/net.IpAddress?=null
      --reuse-address/bool=true
      --reuse-port/bool=false
      --loopback/bool=true
      --ttl/int=1:
    client ::= client_ as NetworkServiceClientBase
    socket ::= client.udp-open-multicast handle_
        address.to-byte-array
        port
        (if-addr ? if-addr.to-byte-array : null)
        reuse-address
        reuse-port
        loopback
        ttl
    return UdpSocketResourceProxy_ client socket

  tcp-connect address/net.SocketAddress -> tcp.Socket:
    client ::= client_ as NetworkServiceClientBase
    socket ::= client.tcp-connect handle_ address.ip.to-byte-array address.port
    return TcpSocketResourceProxy_ client socket

  tcp-listen port/int -> tcp.ServerSocket:
    client ::= client_ as NetworkServiceClientBase
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
    module := module_
    if module: return module
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

  up [--if-unconnected] -> NetworkModule?:
    module := module_
    if module:
      usage_++
      return module
    if-unconnected.call
    return null

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
    if index == NetworkService.UDP-OPEN-MULTICAST-INDEX:
      if not network_ is udp.MulticastInterface: throw "UNSUPPORTED"
      socket ::= (network_ as udp.MulticastInterface).udp-open-multicast
          (net.IpAddress arguments[0])
          arguments[1]
          --if-addr=(arguments[2] ? net.IpAddress arguments[2] : null)
          --reuse-address=arguments[3]
          --reuse-port=arguments[4]
          --loopback=arguments[5]
          --ttl=arguments[6]
      return ProxyingSocketResource_ this client socket
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
      if option == NetworkService.SOCKET-OPTION-UDP-MULTICAST-LOOPBACK:
        return socket.multicast-loopback
      if option == NetworkService.SOCKET-OPTION-UDP-MULTICAST-TTL:
        return socket.multicast-ttl
      if option == NetworkService.SOCKET-OPTION-UDP-REUSE-ADDRESS:
        return socket.reuse-address
      if option == NetworkService.SOCKET-OPTION-UDP-REUSE-PORT:
        return socket.reuse-port
      if option == NetworkService.SOCKET-OPTION-TCP-NO-DELAY:
        return socket.no-delay
    if index == NetworkService.SOCKET-SET-OPTION-INDEX:
      socket ::= convert-to-socket_ client arguments[0]
      option ::= arguments[1]
      value ::= arguments[2]
      if option == NetworkService.SOCKET-OPTION-UDP-BROADCAST:
        return socket.broadcast = value

      if option == NetworkService.SOCKET-OPTION-UDP-MULTICAST-MEMBERSHIP:
        return socket.multicast-add-membership (net.IpAddress value)
      if option == NetworkService.SOCKET-OPTION-UDP-MULTICAST-LOOPBACK:
        return socket.multicast-loopback = value
      if option == NetworkService.SOCKET-OPTION-UDP-MULTICAST-TTL:
        return socket.multicast-ttl = value
      if option == NetworkService.SOCKET-OPTION-UDP-REUSE-ADDRESS:
        return socket.reuse-address = value
      if option == NetworkService.SOCKET-OPTION-UDP-REUSE-PORT:
        return socket.reuse-port = value
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

class SocketResourceProxy_ extends ServiceResourceProxy with io.CloseableInMixin io.CloseableOutMixin:
  static WRITE-DATA-SIZE-MAX_ /int ::= 2048

  constructor client/NetworkServiceClientBase handle/int:
    super client handle

  local-address -> net.SocketAddress:
    client ::= client_ as NetworkServiceClientBase
    return convert-to-socket-address_ (client.socket-local-address handle_)

  peer-address -> net.SocketAddress:
    client ::= client_ as NetworkServiceClientBase
    return convert-to-socket-address_ (client.socket-peer-address handle_)

  read -> ByteArray?:
    return read_

  read_ -> ByteArray?:
    return (client_ as NetworkServiceClientBase).socket-read handle_

  write data/io.Data from/int=0 to/int=data.byte-size -> int:
    return try-write_ data from to

  try-write_ data/io.Data from/int to/int -> int:
    to = min to (from + WRITE-DATA-SIZE-MAX_)
    return (client_ as NetworkServiceClientBase).socket-write handle_ (data.byte-slice from  to)

  mtu -> int:
    return (client_ as NetworkServiceClientBase).socket-mtu handle_

  /**
  Closes the proxied socket for write. The socket will still be able to read incoming data.
  Deprecated. Use ($out).close instead.
  */
  close-write -> none:
    out.close

  close-writer_ -> none:
    (client_ as NetworkServiceClientBase).tcp-close-write handle_

  close-reader_:
    // TODO(florian): Implement this.

class UdpSocketResourceProxy_ extends SocketResourceProxy_ implements udp.Socket udp.MulticastSocket:
  constructor client/NetworkServiceClientBase handle/int:
    super client handle

  receive -> udp.Datagram:
    result ::= (client_ as NetworkServiceClientBase).udp-receive handle_
    return udp.Datagram result[0] (convert-to-socket-address_ result 1)

  send datagram/udp.Datagram -> none:
    address ::= datagram.address
    client ::= client_ as NetworkServiceClientBase
    client.udp-send handle_ datagram.data address.ip.to-byte-array address.port

  connect address/net.SocketAddress -> none:
    client ::= client_ as NetworkServiceClientBase
    client.udp-connect handle_ address.ip.to-byte-array address.port

  broadcast -> bool:
    client ::= client_ as NetworkServiceClientBase
    return client.socket-get-option handle_ NetworkService.SOCKET-OPTION-UDP-BROADCAST

  broadcast= value/bool:
    client ::= client_ as NetworkServiceClientBase
    client.socket-set-option handle_ NetworkService.SOCKET-OPTION-UDP-BROADCAST value

  multicast-add-membership address/net.IpAddress:
    client ::= client_ as NetworkServiceClientBase
    client.socket-set-option handle_ NetworkService.SOCKET-OPTION-UDP-MULTICAST-MEMBERSHIP address.to-byte-array

  multicast-loopback -> bool:
    client ::= client_ as NetworkServiceClientBase
    return client.socket-get-option handle_ NetworkService.SOCKET-OPTION-UDP-MULTICAST-LOOPBACK

  multicast-loopback= value/bool:
    client ::= client_ as NetworkServiceClientBase
    client.socket-set-option handle_ NetworkService.SOCKET-OPTION-UDP-MULTICAST-LOOPBACK value

  multicast-ttl -> int:
    client ::= client_ as NetworkServiceClientBase
    return client.socket-get-option handle_ NetworkService.SOCKET-OPTION-UDP-MULTICAST-TTL

  multicast-ttl= value/int:
    client ::= client_ as NetworkServiceClientBase
    client.socket-set-option handle_ NetworkService.SOCKET-OPTION-UDP-MULTICAST-TTL value

  reuse-address -> bool:
    client ::= client_ as NetworkServiceClientBase
    return client.socket-get-option handle_ NetworkService.SOCKET-OPTION-UDP-REUSE-ADDRESS

  reuse-address= value/bool:
    client ::= client_ as NetworkServiceClientBase
    client.socket-set-option handle_ NetworkService.SOCKET-OPTION-UDP-REUSE-ADDRESS value

  reuse-port -> bool:
    client ::= client_ as NetworkServiceClientBase
    return client.socket-get-option handle_ NetworkService.SOCKET-OPTION-UDP-REUSE-PORT

  reuse-port= value/bool:
    client ::= client_ as NetworkServiceClientBase
    client.socket-set-option handle_ NetworkService.SOCKET-OPTION-UDP-REUSE-PORT value

class TcpSocketResourceProxy_ extends SocketResourceProxy_ implements tcp.Socket:
  constructor client/NetworkServiceClientBase handle/int:
    super client handle

  no-delay -> bool:
    client ::= client_ as NetworkServiceClientBase
    return client.socket-get-option handle_ NetworkService.SOCKET-OPTION-TCP-NO-DELAY

  no-delay= value/bool -> none:
    client ::= client_ as NetworkServiceClientBase
    client.socket-set-option handle_ NetworkService.SOCKET-OPTION-TCP-NO-DELAY value

class TcpServerSocketResourceProxy_ extends ServiceResourceProxy implements tcp.ServerSocket:
  constructor client/NetworkServiceClientBase handle/int:
    super client handle

  local-address -> net.SocketAddress:
    client ::= client_ as NetworkServiceClientBase
    return convert-to-socket-address_ (client.socket-local-address handle_)

  accept -> tcp.Socket?:
    client ::= client_ as NetworkServiceClientBase
    socket ::= client.tcp-accept handle_
    return TcpSocketResourceProxy_ client socket

class ProxyingSocketResource_ extends ServiceResource:
  socket/any ::= ?
  constructor provider/ServiceProvider client/int .socket:
    super provider client
  on-closed -> none:
    socket.close
