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

import system.services show ServiceHandler ServiceProvider ServiceResource
import system.api.network show NetworkService

abstract class NetworkServiceProviderBase extends ServiceProvider
    implements NetworkService ServiceHandler:
  constructor name/string --major/int --minor/int --tags/List?=null:
    super name --major=major --minor=minor
    provides NetworkService.SELECTOR --handler=this --tags=tags

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == NetworkService.CONNECT-INDEX:
      return connect client
    if index == NetworkService.ADDRESS-INDEX:
      return address (resource client arguments)
    if index == NetworkService.RESOLVE-INDEX:
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
  quarantine name/string -> none:
    unreachable

  udp-open handle/int port/int? -> int:
    unreachable

  udp-open-multicast -> int
      handle/int
      address/ByteArray
      port/int
      if-addr/ByteArray?
      reuse-address/bool
      reuse-port/bool
      loopback/bool
      ttl/int:
    unreachable
  udp-connect handle/int ip/ByteArray port/int -> none:
    unreachable
  udp-receive handle/int -> List:
    unreachable
  udp-send handle/int data/ByteArray ip/ByteArray port/int -> none:
    unreachable

  tcp-connect handle/int ip/ByteArray port/int -> int:
    unreachable
  tcp-listen handle/int port/int -> int:
    unreachable
  tcp-accept handle/int -> int:
    unreachable
  tcp-close-write handle/int -> none:
    unreachable

  socket-get-option handle/int option/string -> any:
    unreachable
  socket-set-option handle/int option/string value/any -> none:
    unreachable
  socket-local-address handle/int -> List:
    unreachable
  socket-peer-address handle/int -> List:
    unreachable
  socket-read handle/int -> ByteArray?:
    unreachable
  socket-write handle/int data -> int:
    unreachable
  socket-mtu handle/int -> int:
    unreachable
