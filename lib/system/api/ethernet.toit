// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.api.network show NetworkService
import system.base.network show NetworkServiceClientBase
import system.services show ServiceSelector

interface EthernetService extends NetworkService:
  static SELECTOR ::= ServiceSelector
      --uuid="7752a0f4-572b-407f-933c-c8a9e4573d29"
      --major=0
      --minor=1

class EthernetServiceClient extends NetworkServiceClientBase implements EthernetService:
  static SELECTOR ::= EthernetService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector
