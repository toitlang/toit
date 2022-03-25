
// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .services

interface ServiceDiscovery:
  static NAME  /string ::= "system/service/discovery"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 1

  static DISCOVER_INDEX /int ::= 0
  discover name/string -> int

  static LISTEN_INDEX /int ::= 1
  listen name/string -> none

  static UNLISTEN_INDEX /int ::= 2
  unlisten name/string -> none

class ServiceDiscoveryClient extends ServiceClient implements ServiceDiscovery:
  constructor.lookup name=ServiceDiscovery.NAME major=ServiceDiscovery.MAJOR minor=ServiceDiscovery.MINOR:
    super.lookup name major minor --server=-1

  discover name/string -> int:
    return invoke_ ServiceDiscovery.DISCOVER_INDEX name

  listen name/string -> none:
    invoke_ ServiceDiscovery.LISTEN_INDEX name

  unlisten name/string -> none:
    invoke_ ServiceDiscovery.UNLISTEN_INDEX name
