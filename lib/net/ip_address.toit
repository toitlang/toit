// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

class IpAddress:
  raw ::= ?

  constructor .raw:
    if raw.size != 4 and raw.size != 16:
      throw "BAD_FORMAT"

  constructor.deserialize bytes/ByteArray:
    return IpAddress bytes

  constructor.parse ip:
    raw = ByteArray 4
    i := 0
    ip.split ".":
      if i > 4: throw "BAD_FORMAT"
      val := int.parse it
      if not 0 <= val <= 255: throw "BAD_FORMAT"
      raw[i] = val
      i++

  operator == other:
    other_raw := other.raw
    if other_raw.size != raw.size: return false
    raw.size.repeat:
      if other_raw[it] != raw[it]: return false
    return true

  hash_code:
    code := 0
    raw.size.repeat:
      code *= 11
      code += raw[it]
      code &= 0xfffff
    return code

  stringify:
    if raw.size == 4:
      buffer := ""
      4.repeat:
        if it != 0: buffer += "."
        buffer += raw[it].stringify
      return buffer

    if raw.size == 16:
      buffer := ""
      8.repeat:
        if it != 0: buffer += ":"
        field := raw[it*2] << 8 | raw[it*2 + 1]
        buffer += field.stringify 16
        // TODO: Consider using compressed format.
      return buffer

    return "<invalid-ip>"

  to_byte_array: return raw
