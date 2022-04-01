// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import system.services show ServiceClient ServiceResourceProxy

interface NetworkService:
  static NAME  /string ::= "system/network"
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
    return (open_ NetworkService.NAME NetworkService.MAJOR NetworkService.MINOR) and this

  connect -> int:
    return invoke_ NetworkService.CONNECT_INDEX null

  address handle/int -> ByteArray:
    return invoke_ NetworkService.ADDRESS_INDEX handle

class NetworkResource extends ServiceResourceProxy:
  constructor client/NetworkServiceClient:
    super client (client.connect)

  address -> net.IpAddress:
    return net.IpAddress
        (client_ as NetworkServiceClient).address handle_
