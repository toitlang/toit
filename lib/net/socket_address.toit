// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import encoding.tison
import .ip_address

class SocketAddress:
  ip/IpAddress ::= ?
  port/int ::= ?

  constructor .ip .port:

  constructor.deserialize bytes/ByteArray:
    values := tison.decode bytes
    return SocketAddress
      IpAddress.deserialize values[0]
      values[1]

  hash_code:
    return (ip.hash_code * 11 + port * 1719) & 0xfffffff

  operator == other:
    if other is not SocketAddress: return false
    return ip == other.ip and port == other.port

  stringify -> string:
    return "$ip:$port"

  to_byte_array:
    return tison.encode [ip.to_byte_array, port]
