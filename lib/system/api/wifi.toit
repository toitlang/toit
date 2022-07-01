// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.api.network show NetworkService NetworkServiceClient

interface WifiService extends NetworkService:
  static UUID  /string ::= "2436edc6-4cd8-4834-8ebc-ed883990da40"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 2

  static CONNECT_INDEX /int ::= 100
  connect keys/List? values/List? -> List

  static ESTABLISH_INDEX /int ::= 101
  establish keys/List? values/List? -> List

class WifiServiceClient extends NetworkServiceClient implements WifiService:
  constructor --open/bool=true:
    super --open=open

  open -> WifiServiceClient?:
    return (open_ WifiService.UUID WifiService.MAJOR WifiService.MINOR) and this

  connect keys/List? values/List? -> List:
    return invoke_ WifiService.CONNECT_INDEX [keys, values]

  establish keys/List? values/List? -> List:
    return invoke_ WifiService.ESTABLISH_INDEX [keys, values]
