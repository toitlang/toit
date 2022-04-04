// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.services show ServiceClient

interface PrintService:
  static NAME  /string ::= "system/print"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 1

  static PRINT_INDEX /int ::= 0
  print message/string -> none

class PrintServiceClient extends ServiceClient implements PrintService:
  constructor --open/bool=true:
    super --open=open

  open -> PrintServiceClient?:
    return (open_ PrintService.NAME PrintService.MAJOR PrintService.MINOR) and this

  print message/string -> none:
    invoke_ PrintService.PRINT_INDEX message
