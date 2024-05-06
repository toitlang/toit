// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.services show ServiceSelector ServiceClient

interface PrintService:
  static SELECTOR ::= ServiceSelector
      --uuid="0b7e3aa1-9fc9-4632-bb09-4605cd11897e"
      --major=0
      --minor=1

  print message/string -> none
  static PRINT-INDEX /int ::= 0

class PrintServiceClient extends ServiceClient implements PrintService:
  static SELECTOR ::= PrintService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  print message/string -> none:
    invoke_ PrintService.PRINT-INDEX message
