// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.services show ServiceSelector ServiceClient

interface LogService:
  static SELECTOR ::= ServiceSelector
      --uuid="89e6340c-67f5-4055-b1d1-b4f4c2755f67"
      --major=0
      --minor=2

  log level/int message/string names/List? keys/List? values/List? timestamp/bool -> none
  static LOG-INDEX /int ::= 0

class LogServiceClient extends ServiceClient implements LogService:
  static SELECTOR ::= LogService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  log level/int message/string names/List? keys/List? values/List? timestamp/bool -> none:
    invoke_ LogService.LOG-INDEX [level, message, names, keys, values, timestamp]
