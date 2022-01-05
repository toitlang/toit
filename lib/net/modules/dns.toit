// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary show BIG_ENDIAN
import net.modules.udp
import net

DNS_DEFAULT_TIMEOUT ::= Duration --s=20
DNS_RETRY_TIMEOUT ::= Duration --s=1
HOSTS_ ::= {"localhost": "127.0.0.1"}

class DnsException:
  text/string

  constructor .text:

  stringify -> string:
    return "DNS lookup exception $text"

/**
Look up a domain name.

If given a numeric address like 127.0.0.1 it merely parses
  the numbers without a network round trip.

Does not currently cache results, so there is normally a
  network round trip on every use.

By default the server is "8.8.8.8" which is the Google DNS
  service.

Currently only works for IPv4, not IPv6.
*/
dns_lookup -> net.IpAddress
    host/string
    --server/string="8.8.8.8"
    --timeout/Duration=DNS_DEFAULT_TIMEOUT:
  q := DnsQuery_ host
  return q.get --server=server --timeout=timeout

class DnsQuery_:
  static A     ::= 1  // A address.
  static CNAME ::= 5  // Canonical name.
  static CLASS ::= 1  // The Internet class.
  id/int
  name/string

  constructor .name:
    id = random 0x10000

  /**
  Look up a domain name.

  If given a numeric address like "127.0.0.1" it merely parses
    the numbers without a network round trip.

  Does not currently cache results, so there is normally a
    network round trip on every use.

  By default the server is "8.8.8.8" which is the Google DNS
    service.

  Currently only works for IPv4, not IPv6.
  */
  get -> net.IpAddress
      --server/string="8.8.8.8"
      --timeout/Duration=DNS_DEFAULT_TIMEOUT:
    if ip_string_:
      return net.IpAddress.parse name
    if HOSTS_.contains name:
      return net.IpAddress.parse HOSTS_[name]

    query := create_query_
    socket := udp.Socket
    with_timeout timeout:
      try:
        socket.connect
          net.SocketAddress
            net.IpAddress.parse server
            53                             // DNS UDP port.

        retry_timeout := DNS_RETRY_TIMEOUT

        // Resend the query with exponential backoff until the outer timeout
        // expires.
        while true:
          socket.write query

          answer := null
          catch:
            with_timeout retry_timeout:
              answer = socket.receive

          if answer:
            return decode_response_ answer.data

          retry_timeout = retry_timeout * 2

      finally:
        socket.close
    unreachable

  static case_compare_ a/string b/string -> bool:
    if a == b: return true
    if a.size != b.size: return false
    a.size.repeat:
      ca := a[it]
      cb := b[it]
      if ca != cb:
        if not is_letter_ ca: return false
        if not is_letter_ cb: return false
        if ca | 0x20 != cb | 0x20: return false
    return true

  static is_letter_ c/int -> bool:
    return 'a' <= c <= 'z' or 'A' <= c <= 'Z'

  ip_string_ -> bool:
    dots := 0
    name.do:
      if it == '.':
        dots++
      else:
        if not '0' <= it <= '9': return false
    return dots == 3

  create_query_ -> ByteArray:
    parts := name.split "."
    length := 1
    parts.do: | part |
      if part.size > 63: throw (DnsException "LABEL_TOO_LARGE")
      if part.size < 1: throw (DnsException "LABEL_TOO_SHORT")
      part.do:
        if it == 0 or it == null: throw (DnsException "INVALID_DOMAIN_NAME")
      length += part.size + 1
    query := ByteArray 12 + length + 4
    BIG_ENDIAN.put_uint16 query 0 id
    query[2] = 0x01  // Set RD bit.
    query_count := 1
    BIG_ENDIAN.put_uint16 query 4 query_count
    position := 12
    parts.do: | part |
      query[position++] = part.size
      query.replace position part
      position += part.size
    query[position++] = 0
    BIG_ENDIAN.put_uint16 query position     A
    BIG_ENDIAN.put_uint16 query position + 2 CLASS
    assert: position + 4 == query.size
    return query

  decode_response_ response/ByteArray -> net.IpAddress:
    received_id := BIG_ENDIAN.uint16 response 0
    if received_id != id:
      throw (DnsException "Response ID mismatch")
    if response[2] != 0x81: throw (DnsException "Unexpected response")
    if response[3] & 0xf != 0: throw (DnsException "Error code $(response[3] & 0xf)")
    position := 12
    queries := BIG_ENDIAN.uint16 response 4
    if queries != 1: throw (DnsException "Unexpected number of queries in response")
    q_name := name_ response position: position = it
    position += 4
    if not case_compare_ q_name name:
      throw (DnsException "Response name mismatch")
    (BIG_ENDIAN.uint16 response 6).repeat:
      r_name := name_ response position: position = it

      type := BIG_ENDIAN.uint16 response position
      position += 2

      clas := BIG_ENDIAN.uint16 response position
      position += 2
      if clas != CLASS: throw (DnsException "Unexpected response class: $clas")

      position += 4  // Skip TTL field.

      rd_length := BIG_ENDIAN.uint16 response position
      position += 2
      if type == A:
        if rd_length != 4: throw (DnsException "Unexpected IP address length $rd_length")
        if case_compare_ r_name q_name:
          return net.IpAddress
              response.copy position position + 4
        // Skip name that does not match.
      else if type == CNAME:
        q_name = name_ response position: null
      position += rd_length
    throw (DnsException "Response did not contain matching A record")

  name_ packet/ByteArray position/int [position_block]:
    parts := []
    parts_ packet position parts position_block
    return parts.join "."

  parts_ packet/ByteArray position/int parts/List [position_block] -> none:
    while packet[position] != 0:
      size := packet[position]
      if size <= 63:
        position++
        parts.add
          packet.to_string position position + size
        position += size
      else:
        if size < 192: throw (DnsException "")
        pointer := (BIG_ENDIAN.uint16 packet position) & 0x3fff
        parts_ packet pointer parts: null
        position_block.call position + 2
        return
    position_block.call position + 1
