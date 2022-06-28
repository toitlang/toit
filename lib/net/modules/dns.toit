// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary show BIG_ENDIAN
import net.modules.udp
import net

DNS_DEFAULT_TIMEOUT ::= Duration --s=20
DNS_RETRY_TIMEOUT ::= Duration --s=1
HOSTS_ ::= {"localhost": "127.0.0.1"}
CACHE_ ::= Map  // From name to CacheEntry.
MAX_CACHE_SIZE_ ::= platform == "FreeRTOS" ? 30 : 1000
MAX_TRIMMED_CACHE_SIZE_ ::= MAX_CACHE_SIZE_ / 3 * 2

class DnsException:
  text/string

  constructor .text:

  stringify -> string:
    return "DNS lookup exception $text"

/**
Look up a domain name.

If given a numeric address like 127.0.0.1 it merely parses
  the numbers without a network round trip.

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

INTERNET_CLASS  ::= 1

A_RECORD        ::= 1
CNAME_RECORD    ::= 5

NO_ERROR        ::= 0
FORMAT_ERROR    ::= 1
SERVER_FAILURE  ::= 2
NAME_ERROR      ::= 3
NOT_IMPLEMENTED ::= 4
REFUSED         ::= 5

class DnsQuery_:
  id/int
  name/string

  constructor .name:
    id = random 0x10000

  /**
  Look up a domain name.

  If given a numeric address like "127.0.0.1" it merely parses
    the numbers without a network round trip.

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

    hit := find_in_cache_ server
    if hit: return hit

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
          exception := catch:
            with_timeout retry_timeout:
              answer = socket.receive
          if exception and exception != "DEADLINE_EXCEEDED": throw exception

          if answer:
            return decode_response_ answer.data server

          retry_timeout = retry_timeout * 1.5

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
    BIG_ENDIAN.put_uint16 query position     A_RECORD
    BIG_ENDIAN.put_uint16 query position + 2 INTERNET_CLASS
    assert: position + 4 == query.size
    return query

  // We pass the name_server because we don't use the cache entry if the user
  // is trying a different name server.
  find_in_cache_ name_server/string -> net.IpAddress?:
    if not CACHE_.contains name: return null
    entry := CACHE_[name]
    if not entry.valid name_server:
      CACHE_.remove name
      return null
    return entry.address

  static ERROR_MESSAGES_ ::= ["", "FORMAT_ERROR", "SERVER_FAILURE", "NO_SUCH_DOMAIN", "NOT_IMPLEMENTED", "REFUSED"]

  decode_response_ response/ByteArray name_server/string -> net.IpAddress:
    received_id := BIG_ENDIAN.uint16 response 0
    if received_id != id:
      throw (DnsException "Response ID mismatch")
    // Check for expected response, but mask out the authoritative bit
    // so we can accept answers that are either authoritative or non-
    // authoritative.
    if response[2] & ~4 != 0x81: throw (DnsException "Unexpected response: $(%x response[2])")
    error := response[3] & 0xf
    if error != NO_ERROR:
      detail := "error code $error"
      if 0 <= error < ERROR_MESSAGES_.size: detail = ERROR_MESSAGES_[error]
      throw (DnsException "Server responded: $detail")
    position := 12
    queries := BIG_ENDIAN.uint16 response 4
    if queries != 1: throw (DnsException "Unexpected number of queries in response")
    q_name := decode_name response position: position = it
    position += 4
    if not case_compare_ q_name name:
      throw (DnsException "Response name mismatch")
    (BIG_ENDIAN.uint16 response 6).repeat:
      r_name := decode_name response position: position = it

      type := BIG_ENDIAN.uint16 response position
      position += 2

      clas := BIG_ENDIAN.uint16 response position
      position += 2
      if clas != INTERNET_CLASS: throw (DnsException "Unexpected response class: $clas")

      ttl := BIG_ENDIAN.int32 response position
      position += 4

      // We won't cache more than a day, even if the TTL is very high.  (In
      // practice TTLs over one hour are rare.)
      ttl = min ttl (3600 * 24)
      // Ignore negative TTLs.
      ttl = max 0 ttl

      rd_length := BIG_ENDIAN.uint16 response position
      position += 2
      if type == A_RECORD:
        if rd_length != 4: throw (DnsException "Unexpected IP address length $rd_length")
        if case_compare_ r_name q_name:
          result := net.IpAddress
              response.copy position position + 4
          if ttl > 0:
            trim_cache_
            CACHE_[name] = CacheEntry result ttl name_server
          return result
        // Skip name that does not match.
      else if type == CNAME_RECORD:
        q_name = decode_name response position: null
      position += rd_length
    throw (DnsException "Response did not contain matching A record")

/**
Decodes a name from a DNS (RFC 1035) packet.
The block is invoked with the index of the next data in the packet.
*/
decode_name packet/ByteArray position/int [position_block] -> string:
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

/// Limits the size of the cache to avoid using too much memory.
trim_cache_ -> none:
  if CACHE_.size < MAX_CACHE_SIZE_: return

  // Cache too big.  Start by removing entries where the TTL has
  // expired.
  now := Time.monotonic_us
  CACHE_.filter --in_place: | key value |
    value.end > now

  // Set the limit a bit lower now - we want to remove at least one third of
  // the entries when we trim the cache since it's an expensive operation.
  if CACHE_.size < MAX_TRIMMED_CACHE_SIZE_: return

  // Remove every second entry.
  toggle := true
  CACHE_.filter --in_place: | key value |
    toggle = not toggle
    toggle

class CacheEntry:
  server / string          // Unparsed server name like "8.8.8.8".
  end / int                // Time in µs, compatible with Time.monotonic_us.
  address / net.IpAddress

  constructor .address ttl/int .server:
    end = Time.monotonic_us + ttl * 1_000_000

  valid name_server/string -> bool:
    if Time.monotonic_us > end: return false
    return name_server == server
