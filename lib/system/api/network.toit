// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import system.services show ServiceClient ServiceResourceProxy

interface NetworkService:
  static UUID  /string ::= "063e228a-3a7a-44a8-b024-d55127255ccb"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 1

  static CONNECT_INDEX /int ::= 0
  connect -> int

  static ADDRESS_INDEX /int ::= 1
  address handle/int -> ByteArray

class NetworkServiceClient extends ServiceClient implements NetworkService:
  constructor --open/bool=true:
    super --open=open

  open -> NetworkServiceClient?:
    return (open_ NetworkService.UUID NetworkService.MAJOR NetworkService.MINOR) and this

  connect -> int:
    return invoke_ NetworkService.CONNECT_INDEX null

  address handle/int -> ByteArray:
    return invoke_ NetworkService.ADDRESS_INDEX handle

class NetworkResource extends ServiceResourceProxy:
  constructor client/NetworkServiceClient handle/int:
    super client handle

  address -> net.IpAddress:
    return net.IpAddress
        (client_ as NetworkServiceClient).address handle_
