// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.services show ServiceClient

interface LoggingService:
  static NAME  /string ::= "system/logging"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 1

  static LOG_INDEX /int ::= 0
  log level/int message/string names/List? keys/List? values/List? -> none

class LoggingServiceClient extends ServiceClient implements LoggingService:
  constructor --open/bool=true:
    super --open=open

  open -> LoggingServiceClient?:
    return (open_ LoggingService.NAME LoggingService.MAJOR LoggingService.MINOR) and this

  log level/int message/string names/List? keys/List? values/List? -> none:
    invoke_ LoggingService.LOG_INDEX [level, message, names, keys, values]
