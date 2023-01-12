// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary show BIG_ENDIAN
import net.modules.udp
import net

DNS_DEFAULT_TIMEOUT ::= Duration --s=20
DNS_RETRY_TIMEOUT ::= Duration --s=1
HOSTS_ ::= {"localhost": "127.0.0.1"}
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

By default the server is determined by the network interface.  The fallback
  servers if none are configured are the Google and Cloudflare DNS services.
*/
dns_lookup -> net.IpAddress
    host/string
    --server/string?=null
    --client/DnsClient?=null
    --timeout/Duration=DNS_DEFAULT_TIMEOUT
    --accept_ipv4/bool=true
    --accept_ipv6/bool=false:
  if server and client: throw "INVALID_ARGUMENT"
  if not client:
    if not server:
      client = default_client
    else:
      client = ALL_CLIENTS_.get server --init=:
        DnsClient [server]
  return client.get host --accept_ipv4=accept_ipv4 --accept_ipv6=accept_ipv6 --timeout=timeout

DEFAULT_CLIENT ::= DnsClient [
    "8.8.8.8",  // Google.
    "1.1.1.1",  // Cloudflare.
    "8.8.4.4",  // Google.
    "1.0.0.1",  // Cloudflare.
]

// A map from IP addresses (in string form) to DNS clients.
// If a DNS client has multiple servers it can query then they
// are separated by slash (/) in the key.
ALL_CLIENTS_ ::= {DEFAULT_CLIENT.servers_.join "/": DEFAULT_CLIENT}

default_client := DEFAULT_CLIENT

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
  query_packet/ByteArray

  constructor .name --.accept_ipv4 --.accept_ipv6:
    id = random 0x10000
    query_packet = create_query_ name id --accept_ipv4=accept_ipv4 --accept_ipv6=accept_ipv6

/**
A DnsClient contains a list of DNS servers in the form of IP addresses in
  string form.
The client picks a DNS server at random.
If a DNS server fails to answer after 2.5 times the $DNS_RETRY_TIMEOUT, then
  the client switches permanently to the next one on the list.
*/
class DnsClient:
  servers_/List
  current_server_/int := ?

  CACHE_ ::= Map  // From name to CacheEntry_.
  CACHE_IPV6_ ::= Map  // From name to CacheEntry_.

  /**
  Creates a DnsClient, given a list of DNS servers in the form of IP addresses
    in string form.
  */
  constructor servers/List:
    if servers.size == 0 or (servers.any: it is not string): throw "INVALID_ARGUMENT"
    servers_ = servers
    current_server_ = random servers.size

  /**
  Look up a domain name and return an A or AAAA record.

  If given a numeric address like "127.0.0.1" it merely parses
    the numbers without a network round trip.
  */
  get name --accept_ipv4/bool=true --accept_ipv6/bool=false -> net.IpAddress
      --timeout/Duration=DNS_DEFAULT_TIMEOUT:
    if net.IpAddress.is_valid name --accept_ipv4=accept_ipv4 --accept_ipv6=accept_ipv6:
      return net.IpAddress.parse name
    if HOSTS_.contains name:
      return net.IpAddress.parse HOSTS_[name]

    hit := find_in_cache_ name --accept_ipv4=accept_ipv4 --accept_ipv6=accept_ipv6
    if hit: return hit

    query := DnsQuery_ name --accept_ipv4=accept_ipv4 --accept_ipv6=accept_ipv6

    with_timeout timeout:
      socket/udp.Socket? := null
      try:
        retry_timeout := DNS_RETRY_TIMEOUT

        // Resend the query with exponential backoff until the outer timeout
        // expires.
        while true:
          if not socket:
            socket = udp.Socket
            socket.connect
              net.SocketAddress
                net.IpAddress.parse servers_[current_server_]
                53                             // DNS UDP port.
          socket.write query.query_packet

          answer := null
          exception := catch:
            with_timeout retry_timeout:
              answer = socket.receive
          if exception and exception != "DEADLINE_EXCEEDED": throw exception

          if answer:
            return decode_response_ query answer.data

          retry_timeout = retry_timeout * 1.5

          if retry_timeout > DNS_RETRY_TIMEOUT * 2:
            // After two short timeouts we rotate to the next server in the
            // list (if any).
            new_server_index := (current_server_ + 1) % servers_.size
            if new_server_index != current_server_:
              // At this point we close the old socket, so if the previous
              // server answers late, we won't see it.
              current_server_ = new_server_index
              socket.close
              socket = null

      finally:
        if socket: socket.close
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

  find_in_cache_ name --accept_ipv4/bool --accept_ipv6/bool -> net.IpAddress?:
    if accept_ipv4:
      if CACHE_.contains name:
        entry := CACHE_[name]
        if entry.valid: return entry.address
        CACHE_.remove name
    if accept_ipv6:
      if CACHE_IPV6_.contains name:
        entry := CACHE_IPV6_[name]
        if entry.valid: return entry.address
        CACHE_IPV6_.remove name
    return null

  static ERROR_MESSAGES_ ::= ["", "FORMAT_ERROR", "SERVER_FAILURE", "NO_SUCH_DOMAIN", "NOT_IMPLEMENTED", "REFUSED"]

  decode_response_ query/DnsQuery_ response/ByteArray -> net.IpAddress:
    received_id := BIG_ENDIAN.uint16 response 0
    if received_id != query.id:
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
    if not case_compare_ q_name query.name:
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
      if type == RECORD_A and query.accept_ipv4:
        if rd_length != 4: throw (DnsException "Unexpected IP address length $rd_length")
        if case_compare_ r_name q_name:
          result := net.IpAddress
              response.copy position position + 4
          if ttl > 0:
            trim_cache_ CACHE_
            CACHE_[query.name] = CacheEntry_ result ttl
          return result
        // Skip name that does not match.
      else if type == RECORD_AAAA and query.accept_ipv6:
        if rd_length != 16: throw (DnsException "Unexpected IP address length $rd_length")
        if case_compare_ r_name q_name:
          result := net.IpAddress
              response.copy position position + 16
          if ttl > 0:
            trim_cache_ CACHE_IPV6_
            CACHE_IPV6_[query.name] = CacheEntry_ result ttl
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
  end / int                // Time in µs, compatible with Time.monotonic_us.
  address / net.IpAddress

  constructor .address ttl/int:
    end = Time.monotonic_us + ttl * 1_000_000

  valid -> bool:
    return Time.monotonic_us <= end

/**
Creates a UDP packet to look up the given name.
Regular DNS lookup is used, namely the A record for the domain.
The $query_id should be a 16 bit unsigned number which will be included in
  the reply.
*/
create_query_ name/string query_id/int --accept_ipv4/bool=true --accept_ipv6/bool=false -> ByteArray:
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
