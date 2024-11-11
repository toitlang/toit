// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.api.network show NetworkService
import system.base.network show NetworkServiceClientBase
import system.services show ServiceSelector

interface WifiService extends NetworkService:
  static SELECTOR ::= ServiceSelector
      --uuid="2436edc6-4cd8-4834-8ebc-ed883990da40"
      --major=0
      --minor=9

  connect config/Map? -> List
  static CONNECT-INDEX /int ::= 1000

  establish config/Map? -> List
  static ESTABLISH-INDEX /int ::= 1001

  ap-info handle/int -> int?
  static AP-INFO-INDEX /int ::= 1002

  scan config/Map -> List
  static SCAN-INDEX /int ::= 1003

  configure config/Map? -> none
  static CONFIGURE-INDEX /int ::= 1004

class WifiServiceClient extends NetworkServiceClientBase implements WifiService:
  static SELECTOR ::= WifiService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  connect config/Map? -> List:
    return invoke_ WifiService.CONNECT-INDEX config

  establish config/Map? -> List:
    return invoke_ WifiService.ESTABLISH-INDEX config

  ap-info handle/int -> List:
    return invoke_ WifiService.AP-INFO-INDEX handle

  scan config/Map -> List:
    return invoke_ WifiService.SCAN-INDEX config

  configure config/Map? -> none:
    invoke_ WifiService.CONFIGURE-INDEX config
