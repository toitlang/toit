// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.api.network show NetworkService NetworkServiceClient

interface WifiService extends NetworkService:
  static UUID  /string ::= "2436edc6-4cd8-4834-8ebc-ed883990da40"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 8

  static CONNECT_INDEX /int ::= 1000
  connect config/Map? save/bool -> List

  static ESTABLISH_INDEX /int ::= 1001
  establish config/Map? -> List

  static RSSI_INDEX /int ::= 1002
  rssi handle/int -> int?

  static SCAN_INDEX /int ::= 1003
  scan config/Map -> List

class WifiServiceClient extends NetworkServiceClient implements WifiService:
  constructor --open/bool=true:
    super --open=open

  open -> WifiServiceClient?:
    return (open_ WifiService.UUID WifiService.MAJOR WifiService.MINOR) and this

  connect config/Map? save/bool -> List:
    return invoke_ WifiService.CONNECT_INDEX [config, save]

  establish config/Map? -> List:
    return invoke_ WifiService.ESTABLISH_INDEX config

  rssi handle/int -> int?:
    return invoke_ WifiService.RSSI_INDEX handle

  scan config/Map -> List:
    return invoke_ WifiService.SCAN_INDEX config
