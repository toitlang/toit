// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.services show ServiceClient

interface LoggingService:
  static UUID  /string ::= "89e6340c-67f5-4055-b1d1-b4f4c2755f67"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 1

  static LOG_INDEX /int ::= 0
  log level/int message/string names/List? keys/List? values/List? trace/ByteArray? -> none

class LoggingServiceClient extends ServiceClient implements LoggingService:
  constructor --open/bool=true:
    super --open=open

  open -> LoggingServiceClient?:
    return (open_ LoggingService.UUID LoggingService.MAJOR LoggingService.MINOR) and this

  log level/int message/string names/List? keys/List? values/List? trace/ByteArray? -> none:
    invoke_ LoggingService.LOG_INDEX [level, message, names, keys, values, trace]
