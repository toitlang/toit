// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.api.network show NetworkService NetworkServiceClient

interface CellularService extends NetworkService:
  static UUID  /string ::= "83798564-d965-49bf-b69d-7f05a082f4f0"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 1

  static CONNECT_INDEX /int ::= 1000
  connect keys/List? values/List? -> List

class CellularServiceClient extends NetworkServiceClient implements CellularService:
  constructor --open/bool=true:
    super --open=open

  open -> CellularServiceClient?:
    return (open_ CellularService.UUID CellularService.MAJOR CellularService.MINOR) and this

  connect keys/List? values/List? -> List:
    return invoke_ CellularService.CONNECT_INDEX [keys, values]
