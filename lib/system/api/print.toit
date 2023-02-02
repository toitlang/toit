// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.services show ServiceSelector ServiceClient

interface PrintService:
  static UUID  /string ::= "0b7e3aa1-9fc9-4632-bb09-4605cd11897e"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 1
  static SELECTOR ::= ServiceSelector
      --uuid=UUID
      --major=MAJOR
      --minor=MINOR

  print message/string -> none
  static PRINT_INDEX /int ::= 0

class PrintServiceClient extends ServiceClient implements PrintService:
  constructor selector/ServiceSelector=PrintService.SELECTOR:
    super selector

  print message/string -> none:
    invoke_ PrintService.PRINT_INDEX message
