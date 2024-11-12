// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.api.network show NetworkService
import system.base.network show NetworkServiceClientBase
import system.services show ServiceSelector

interface CellularService extends NetworkService:
  static SELECTOR ::= ServiceSelector
      --uuid="83798564-d965-49bf-b69d-7f05a082f4f0"
      --major=0
      --minor=2

  connect config/Map? -> List
  static CONNECT-INDEX /int ::= 1000

class CellularServiceClient extends NetworkServiceClientBase implements CellularService:
  static SELECTOR ::= CellularService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  connect config/Map? -> List:
    return invoke_ CellularService.CONNECT-INDEX config
