
// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.services show ServiceClient ServiceSelector

interface ServiceDiscoveryService:
  static SELECTOR ::= ServiceSelector
      --uuid="dc58d7e1-1b1f-4a93-a9ac-bd45a47d7de8"
      --major=0
      --minor=3

  discover uuid/string --wait/bool -> List?
  static DISCOVER_INDEX /int ::= 0

  watch pid/int -> none
  static WATCH_INDEX /int ::= 3

  listen id/int uuid/string -> none
      --name/string
      --major/int
      --minor/int
      --priority/int
      --tags/List?
  static LISTEN_INDEX /int ::= 1

  unlisten id/int -> none
  static UNLISTEN_INDEX /int ::= 2

class ServiceDiscoveryServiceClient extends ServiceClient implements ServiceDiscoveryService:
  constructor selector/ServiceSelector=ServiceDiscoveryService.SELECTOR:
    super selector

  open -> ServiceDiscoveryServiceClient?:
    client := _open_ selector --pid=-1 --id=0  // Hardcoded in system process.
    return client and this

  discover uuid/string --wait/bool -> List?:
    return invoke_ ServiceDiscoveryService.DISCOVER_INDEX [uuid, wait]

  watch pid/int -> none:
    invoke_ ServiceDiscoveryService.WATCH_INDEX pid

  listen id/int uuid/string -> none
      --name/string
      --major/int
      --minor/int
      --priority/int
      --tags/List?:
    invoke_ ServiceDiscoveryService.LISTEN_INDEX [
      id, uuid, name, major, minor, priority, tags
    ]

  unlisten id/int -> none:
    invoke_ ServiceDiscoveryService.UNLISTEN_INDEX id
