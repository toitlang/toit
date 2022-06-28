// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import net.udp
import net.tcp

import system.services show ServiceClient

// For references in documentation comments.
import system.services show ServiceResource ServiceResourceProxy

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

  /**
  The notification constants are used as arguments to $ServiceResource.notify_
    and consequently $ServiceResourceProxy.on_notified_.
  */
  static NOTIFY_CLOSED /int ::= 200

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
