// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.api.network show NetworkService NetworkServiceClient

interface WifiService extends NetworkService:
  static UUID  /string ::= "2436edc6-4cd8-4834-8ebc-ed883990da40"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 9

  connect config/Map? -> List
  static CONNECT_INDEX /int ::= 1000

  establish config/Map? -> List
  static ESTABLISH_INDEX /int ::= 1001

  ap_info handle/int -> int?
  static AP_INFO_INDEX /int ::= 1002

  scan config/Map -> List
  static SCAN_INDEX /int ::= 1003

  configure config/Map? -> none
  static CONFIGURE_INDEX /int ::= 1004

class WifiServiceClient extends NetworkServiceClient implements WifiService:
  constructor --open/bool=true:
    super --open=open

  open -> WifiServiceClient?:
    return (open_ WifiService.UUID WifiService.MAJOR WifiService.MINOR) and this

  connect config/Map? -> List:
    return invoke_ WifiService.CONNECT_INDEX config

  establish config/Map? -> List:
    return invoke_ WifiService.ESTABLISH_INDEX config

  ap_info handle/int -> List:
    return invoke_ WifiService.AP_INFO_INDEX handle

  scan config/Map -> List:
    return invoke_ WifiService.SCAN_INDEX config

  configure config/Map? -> none:
    invoke_ WifiService.CONFIGURE_INDEX config
