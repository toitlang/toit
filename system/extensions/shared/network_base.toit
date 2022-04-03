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
  constructor name/string=NetworkService.NAME
      --major/int=NetworkService.MAJOR
      --minor/int=NetworkService.MINOR:
    super name --major=major --minor=minor

  handle pid/int client/int index/int arguments/any -> any:
    if index == NetworkService.CONNECT_INDEX:
      return connect client
    if index == NetworkService.ADDRESS_INDEX:
      return address (resource client arguments)
    unreachable

  connect -> int:
    unreachable  // TODO(kasper): Nasty.

  abstract connect client/int -> ServiceResource
  abstract address resource/ServiceResource -> ByteArray
