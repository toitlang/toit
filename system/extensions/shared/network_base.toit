// Copyright (C) 2022 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import system.services show ServiceDefinition ServiceResource
import system.api.network show NetworkService

abstract class NetworkServiceDefinitionBase extends ServiceDefinition implements NetworkService:
  constructor name/string --major/int --minor/int:
    super name --major=major --minor=minor
    provides NetworkService.UUID NetworkService.MAJOR NetworkService.MINOR

  handle pid/int client/int index/int arguments/any -> any:
    if index == NetworkService.CONNECT_INDEX:
      return connect client
    if index == NetworkService.ADDRESS_INDEX:
      return address (resource client arguments)
    if index == NetworkService.RESOLVE_INDEX:
      return resolve (resource client arguments[0]) arguments[1]
    unreachable

  connect -> List:
    unreachable  // TODO(kasper): Nasty.

  abstract connect client/int -> ServiceResource

  // Service clients should not call the following methods. This service definition
  // hasn't asked for these calls to be proxied (through the returned mask), so the
  // client must implement them.
  address resource/ServiceResource -> ByteArray:
    unreachable
  resolve resource/ServiceResource host/string -> List:
    unreachable

  udp_open handle/int port/int? -> int:
    unreachable
  udp_connect handle/int ip/ByteArray port/int -> none:
    unreachable
  udp_receive handle/int -> List:
    unreachable
  udp_send handle/int data/ByteArray ip/ByteArray port/int -> none:
    unreachable

  tcp_connect handle/int ip/ByteArray port/int -> int:
    unreachable
  tcp_listen handle/int port/int -> int:
    unreachable
  tcp_accept handle/int -> int:
    unreachable
  tcp_close_write handle/int -> none:
    unreachable

  socket_get_option handle/int option/string -> any:
    unreachable
  socket_set_option handle/int option/string value/any -> none:
    unreachable
  socket_local_address handle/int -> List:
    unreachable
  socket_peer_address handle/int -> List:
    unreachable
  socket_read handle/int -> ByteArray?:
    unreachable
  socket_write handle/int data -> int:
    unreachable
  socket_mtu handle/int -> int:
    unreachable
