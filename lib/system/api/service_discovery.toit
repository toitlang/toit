
// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.services show ServiceClient

interface ServiceDiscoveryService:
  static UUID  /string ::= "dc58d7e1-1b1f-4a93-a9ac-bd45a47d7de8"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 3

  discover uuid/string wait/bool -> List?
  static DISCOVER_INDEX /int ::= 0

  watch pid/int -> none
  static WATCH_INDEX /int ::= 3

  listen id/int uuid/string -> none
  static LISTEN_INDEX /int ::= 1

  unlisten id/int -> none
  static UNLISTEN_INDEX /int ::= 2

class ServiceDiscoveryServiceClient extends ServiceClient implements ServiceDiscoveryService:
  constructor --open/bool=true:
    super --open=open

  open -> ServiceDiscoveryServiceClient?:
    return (open_ ServiceDiscoveryService.UUID ServiceDiscoveryService.MAJOR ServiceDiscoveryService.MINOR --pid=-1) and this

  discover uuid/string wait/bool -> List?:
    return invoke_ ServiceDiscoveryService.DISCOVER_INDEX [uuid, wait]

  watch pid/int -> none:
    invoke_ ServiceDiscoveryService.WATCH_INDEX pid

  listen id/int uuid/string -> none:
    invoke_ ServiceDiscoveryService.LISTEN_INDEX [id, uuid]

  unlisten id/int -> none:
    invoke_ ServiceDiscoveryService.UNLISTEN_INDEX id
