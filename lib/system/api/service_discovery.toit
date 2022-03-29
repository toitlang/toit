
// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.services show ServiceClient

interface ServiceDiscoveryService:
  static NAME  /string ::= "system/service-discovery"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 1

  static DISCOVER_INDEX /int ::= 0
  discover name/string -> int?

  static LISTEN_INDEX /int ::= 1
  listen name/string -> none

  static UNLISTEN_INDEX /int ::= 2
  unlisten name/string -> none

class ServiceDiscoveryServiceClient extends ServiceClient implements ServiceDiscoveryService:
  constructor --open/bool=true:
    super --open=open

  open -> ServiceDiscoveryServiceClient?:
    return (open_ ServiceDiscoveryService.NAME ServiceDiscoveryService.MAJOR ServiceDiscoveryService.MINOR --pid=-1) and this

  discover name/string -> int?:
    return invoke_ ServiceDiscoveryService.DISCOVER_INDEX name

  listen name/string -> none:
    invoke_ ServiceDiscoveryService.LISTEN_INDEX name

  unlisten name/string -> none:
    invoke_ ServiceDiscoveryService.UNLISTEN_INDEX name
