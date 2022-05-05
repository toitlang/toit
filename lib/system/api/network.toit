// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import system.services show ServiceClient ServiceResourceProxy

interface NetworkService:
  static UUID  /string ::= "063e228a-3a7a-44a8-b024-d55127255ccb"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 2

  /**
  Proxy mask bits that indicate which operations must be proxied
    through the service. See $connect.
  */
  static PROXY_ADDRESS /int ::= 1 << 0
  static PROXY_RESOLVE /int ::= 1 << 1

  // The connect call returns a handle to the network resource and
  // the proxy mask bits in a list. The proxy mask bits indicate
  // which operations the service definition wants the client to
  // proxy through it.
  static CONNECT_INDEX /int ::= 0
  connect -> List

  static ADDRESS_INDEX /int ::= 1
  address handle/int -> ByteArray

  static RESOLVE_INDEX /int ::= 2
  resolve handle/int host/string -> List

class NetworkServiceClient extends ServiceClient implements NetworkService:
  constructor --open/bool=true:
    super --open=open

  open -> NetworkServiceClient?:
    return (open_ NetworkService.UUID NetworkService.MAJOR NetworkService.MINOR) and this

  connect -> List:
    return invoke_ NetworkService.CONNECT_INDEX null

  address handle/int -> ByteArray:
    return invoke_ NetworkService.ADDRESS_INDEX handle

  resolve handle/int host/string -> List:
    return invoke_ NetworkService.RESOLVE_INDEX [handle, host]

class NetworkResource extends ServiceResourceProxy:
  constructor client/NetworkServiceClient handle/int:
    super client handle

  address -> net.IpAddress:
    return net.IpAddress
        (client_ as NetworkServiceClient).address handle_

  resolve host/string -> List:
    results := (client_ as NetworkServiceClient).resolve handle_ host
    return results.map: net.IpAddress it
