// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary show BIG_ENDIAN
import net.modules.udp
import net

DNS_DEFAULT_TIMEOUT ::= Duration --s=20
DNS_RETRY_TIMEOUT ::= Duration --s=1
HOSTS_ ::= {"localhost": "127.0.0.1"}
CACHE_ ::= Map  // From name to CacheEntry_.
CACHE_IPV6_ ::= Map  // From name to CacheEntry_.
MAX_CACHE_SIZE_ ::= platform == "FreeRTOS" ? 30 : 1000
MAX_TRIMMED_CACHE_SIZE_ ::= MAX_CACHE_SIZE_ / 3 * 2

class DnsException:
  text/string

  constructor .text:

  stringify -> string:
    return "DNS lookup exception $text"

/**
Look up a domain name and return an A or AAAA record.

If given a numeric address like 127.0.0.1 it merely parses
  the numbers without a network round trip.

By default the server is "8.8.8.8" which is the Google DNS
  service.
*/
dns_lookup -> net.IpAddress
    host/string
    --server/string="8.8.8.8"
    --timeout/Duration=DNS_DEFAULT_TIMEOUT
    --accept_ipv4/bool=true
    --accept_ipv6/bool=false:
  q := DnsQuery_ host --accept_ipv4=accept_ipv4 --accept_ipv6=accept_ipv6
  return q.get --server=server --timeout=timeout

CLASS_INTERNET ::= 1

RECORD_A       ::= 1
RECORD_CNAME   ::= 5
RECORD_AAAA    ::= 28  // IPv6 DNS lookup.

ERROR_NONE            ::= 0
ERROR_FORMAT          ::= 1
ERROR_SERVER_FAILURE  ::= 2
ERROR_NAME            ::= 3
ERROR_NOT_IMPLEMENTED ::= 4
ERROR_REFUSED         ::= 5

class DnsQuery_:
  id/int
  name/string
  accept_ipv4/bool
  accept_ipv6/bool

  constructor .name --.accept_ipv4 --.accept_ipv6:
    id = random 0x10000

  /**
  Look up a domain name and return an A or AAAA record.

  If given a numeric address like "127.0.0.1" it merely parses
    the numbers without a network round trip.

  By default the server is "8.8.8.8" which is the Google DNS
    service.
  */
  get -> net.IpAddress
      --server/string="8.8.8.8"
      --timeout/Duration=DNS_DEFAULT_TIMEOUT:
    if net.IpAddress.is_valid name --accept_ipv4=accept_ipv4 --accept_ipv6=accept_ipv6:
      return net.IpAddress.parse name
    if HOSTS_.contains name:
      return net.IpAddress.parse HOSTS_[name]

    hit := find_in_cache_ server --accept_ipv4=accept_ipv4 --accept_ipv6=accept_ipv6
    if hit: return hit

    query := create_query name id --accept_ipv4=accept_ipv4 --accept_ipv6=accept_ipv6

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

  // We pass the name_server because we don't use the cache entry if the user
  // is trying a different name server.
  find_in_cache_ name_server/string --accept_ipv4/bool --accept_ipv6/bool -> net.IpAddress?:
    if accept_ipv4:
      if CACHE_.contains name:
        entry := CACHE_[name]
        if entry.valid name_server: return entry.address
        CACHE_.remove name
    if accept_ipv6:
      if CACHE_IPV6_.contains name:
        entry := CACHE_IPV6_[name]
        if entry.valid name_server: return entry.address
        CACHE_IPV6_.remove name
    return null

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
    if error != ERROR_NONE:
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
      if clas != CLASS_INTERNET: throw (DnsException "Unexpected response class: $clas")

      ttl := BIG_ENDIAN.int32 response position
      position += 4

      // We won't cache more than a day, even if the TTL is very high.  (In
      // practice TTLs over one hour are rare.)
      ttl = min ttl (3600 * 24)
      // Ignore negative TTLs.
      ttl = max 0 ttl

      rd_length := BIG_ENDIAN.uint16 response position
      position += 2
      if type == RECORD_A and accept_ipv4:
        if rd_length != 4: throw (DnsException "Unexpected IP address length $rd_length")
        if case_compare_ r_name q_name:
          result := net.IpAddress
              response.copy position position + 4
          if ttl > 0:
            trim_cache_ CACHE_
            CACHE_[name] = CacheEntry_ result ttl name_server
          return result
        // Skip name that does not match.
      else if type == RECORD_AAAA and accept_ipv6:
        if rd_length != 16: throw (DnsException "Unexpected IP address length $rd_length")
        if case_compare_ r_name q_name:
          result := net.IpAddress
              response.copy position position + 16
          if ttl > 0:
            trim_cache_ CACHE_IPV6_
            CACHE_IPV6_[name] = CacheEntry_ result ttl name_server
          return result
      else if type == RECORD_CNAME:
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
trim_cache_ cache/Map -> none:
  if cache.size < MAX_CACHE_SIZE_: return

  // Cache too big.  Start by removing entries where the TTL has
  // expired.
  now := Time.monotonic_us
  cache.filter --in_place: | key value |
    value.end > now

  // Set the limit a bit lower now - we want to remove at least one third of
  // the entries when we trim the cache since it's an expensive operation.
  if cache.size < MAX_TRIMMED_CACHE_SIZE_: return

  // Remove every second entry.
  toggle := true
  cache.filter --in_place: | key value |
    toggle = not toggle
    toggle

class CacheEntry_:
  server / string          // Unparsed server name like "8.8.8.8".
  end / int                // Time in µs, compatible with Time.monotonic_us.
  address / net.IpAddress

  constructor .address ttl/int .server:
    end = Time.monotonic_us + ttl * 1_000_000

  valid name_server/string -> bool:
    if Time.monotonic_us > end: return false
    return name_server == server

/**
Creates a UDP packet to look up the given name.
Regular DNS lookup is used, namely the A record for the domain.
The $query_id should be a 16 bit unsigned number which will be included in
  the reply.
*/
create_query name/string query_id/int --accept_ipv4/bool=true --accept_ipv6/bool=false -> ByteArray:
  if not (accept_ipv4 or accept_ipv6): throw "INVALID_ARGUMENT"
  query_count := (accept_ipv4 and accept_ipv6) ? 2 : 1
  parts := name.split "."
  length := 1
  parts.do: | part |
    if part.size > 63: throw (DnsException "DNS name parts cannot exceed 63 bytes")
    if part.size < 1: throw (DnsException "DNS name parts cannot be empty")
    part.do:
      if it == 0 or it == null: throw (DnsException "INVALID_DOMAIN_NAME")
    length += part.size + 1
  query := ByteArray 10 + length + query_count * 6
  BIG_ENDIAN.put_uint16 query 0 query_id
  query[2] = 0x01  // Set RD bit.
  BIG_ENDIAN.put_uint16 query 4 query_count
  position := 12
  name_offset := position
  parts.do: | part |
    query[position++] = part.size
    query.replace position part
    position += part.size
  query[position++] = 0
  BIG_ENDIAN.put_uint16 query position     (accept_ipv4 ? RECORD_A : RECORD_AAAA)
  BIG_ENDIAN.put_uint16 query position + 2 CLASS_INTERNET
  position += 4
  if query_count == 2:
    // Point to the name from the first quety.
    BIG_ENDIAN.put_uint16 query position     0b1100_0000_0000_0000 + name_offset
    BIG_ENDIAN.put_uint16 query position + 2 RECORD_AAAA
    BIG_ENDIAN.put_uint16 query position + 4 CLASS_INTERNET
    position += 6
  assert: position == query.size
  return query
