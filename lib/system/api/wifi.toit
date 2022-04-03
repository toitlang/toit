// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.api.network show NetworkService NetworkServiceClient

interface WifiService extends NetworkService:
  static NAME  /string ::= "system/network/wifi"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 1

  static CONNECT_SSID_PASSWORD_INDEX /int ::= 100
  connect ssid/string password/string -> int

class WifiServiceClient extends NetworkServiceClient implements WifiService:
  constructor --open/bool=true:
    super --open=open

  open -> WifiServiceClient?:
    return (open_ WifiService.NAME WifiService.MAJOR WifiService.MINOR) and this

  connect ssid/string password/string -> int:
    return invoke_ WifiService.CONNECT_SSID_PASSWORD_INDEX [ssid, password]
