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
    if i != 4: throw "BAD_FORMAT"

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
      return (List 4: raw[it]).join "."

    if raw.size == 16:
      return (List 8: raw[it * 2] << 8 | raw[it * 2 + 1]).join ":"

    return "<invalid-ip>"

  to_byte_array: return raw

  /**
  Checks a string to detect if it is a parseable IP address.
  IPv4 addresses are checked for decimal dot notation, eg. 192.168.0.1
  IPv6 addresses are checked for hexadecimal colon notation, eg. 2001:db8::1234:5678
  */
  static is_valid str/string --accept_ipv4/bool=true --accept_ipv6/bool=false -> bool:
    if accept_ipv4 and ipv4_string_ str: return true
    return accept_ipv6 and ipv6_string_ str

  static ipv4_string_ str/string -> bool:
    dots := 0
    last_dot := -1
    str.size.repeat: | i |
      char := str[i]
      if char == '.':
        part := str[last_dot + 1..i]
        if not 1 <= part.size <= 3: return false
        if part.size != 1 and part[0] == '0': return false  // Leading zeros.
        if part.size == 3 and (int.parse part) > 255: return false  // Parts must be in byte range.
        last_dot = i
        dots++
      else:
        if not '0' <= char <= '9': return false
    return dots == 3 and last_dot != str.size - 1

  static ipv6_string_ str/string -> bool:
    found_double_colon := false
    parts := 0
    digits_since_last_colon := -1
    str.do:
      if it == ':':
        if digits_since_last_colon > 4:
          return false
        else if digits_since_last_colon > 0:
          parts++
        else if digits_since_last_colon == 0:
          if found_double_colon: return false
          found_double_colon = true
        digits_since_last_colon = 0
      else:
        hex_char_to_value it --on_error=(: return false)
        if digits_since_last_colon < 0:
          digits_since_last_colon = 1
        else:
          digits_since_last_colon++
    if 1 <= digits_since_last_colon <= 4:
      parts++
    else if not str.ends_with "::":
      return false
    return (parts == 8 or (parts < 8 and found_double_colon))
