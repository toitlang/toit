// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary show BIG-ENDIAN
import net.modules.udp as udp-module
import net

DNS-DEFAULT-TIMEOUT ::= Duration --s=20
DNS-RETRY-TIMEOUT ::= Duration --ms=600
MAX-RETRY-ATTEMPTS_ ::= 3
HOSTS_ ::= {"localhost": "127.0.0.1"}
MAX-CACHE-SIZE_ ::= platform == "FreeRTOS" ? 30 : 1000
MAX-TRIMMED-CACHE-SIZE_ ::= MAX-CACHE-SIZE_ / 3 * 2

class DnsException:
  text/string
  name/string?

  constructor .text --.name=null:

  stringify -> string:
    if name:
      return "DNS lookup for '$name' exception $text"
    else:
      return "DNS lookup exception $text"

/**
Look up a domain name and return an A or AAAA record.

If given a numeric address like 127.0.0.1 it merely parses
  the numbers without a network round trip.

By default the server is determined by the network interface.  The fallback
  servers if none are configured are the Google and Cloudflare DNS services.

If there are multiple servers then they are tried in rotation until one
  responds.  If one responds with an error (eg. no such domain) we do not try
  the next one.  This is in line with the way that Linux handles multiple
  servers on the same lookup request.
*/
dns-lookup -> net.IpAddress
    host/string
    --server/string?=null
    --client/DnsClient?=null
    --timeout/Duration=DNS-DEFAULT-TIMEOUT
    --accept-ipv4/bool=true
    --accept-ipv6/bool=false:
  if server and client: throw "INVALID_ARGUMENT"
  if not client:
    if not server:
      client = default-client
    else:
      client = AUTO-CREATED-CLIENTS_.get server --init=:
        DnsClient [server]
  return client.get host --accept-ipv4=accept-ipv4 --accept-ipv6=accept-ipv6 --timeout=timeout

DEFAULT-CLIENT ::= DnsClient [
    "8.8.8.8",  // Google.
    "1.1.1.1",  // Cloudflare.
    "8.8.4.4",  // Google.
    "1.0.0.1",  // Cloudflare.
]

// A map from IP addresses (in string form) to DNS clients.
AUTO-CREATED-CLIENTS_ ::= {:}

user-set-client_/DnsClient? := null
dhcp-client_/DnsClient? := null

RESOLV-CONF_ ::= "/etc/resolv.conf"

/**
On Unix systems the default client is one that keeps an eye on changes in
  /etc/resolv.conf.
On FreeRTOS systems the default client is set by DHCP.
On Windows we currently default to using Google and Cloudflare DNS servers.
On all platforms you can set a custom default client with the
  $(default-client= client) setter.
*/
default-client -> DnsClient:
  if user-set-client_: return user-set-client_
  if platform == PLATFORM-FREERTOS and dhcp-client_: return dhcp-client_
  if platform == PLATFORM-LINUX or platform == PLATFORM-MACOS: return etc-resolv-client_
  return DEFAULT-CLIENT

default-client= client/DnsClient? -> none:
  user-set-client_ = client

current-etc-resolv-client_/DnsClient? := null
etc-resolv-update-time_/Time? := null

etc-resolv-client_ -> DnsClient:
  catch --trace:
    resolv-conf-stat := stat_ RESOLV-CONF_ true
    etc-stat := stat_ "/etc" true
    resolv-conf-time := Time.epoch --ns=resolv-conf-stat[ST-MTIME_]
    etc-time := Time.epoch --ns=etc-stat[ST-MTIME_]
    modification-time := resolv-conf-time > etc-time ? resolv-conf-time : etc-time
    if etc-resolv-update-time_ == null or etc-resolv-update-time_ < modification-time:
      etc-resolv-update-time_ = modification-time
      // Create a new client from resolv.conf.
      resolv-conf := (read-file-content-posix_ RESOLV-CONF_ resolv-conf-stat[ST-SIZE_]).to-string
      nameservers := []
      resolv-conf.split "\n": | line |
        hash := line.index-of "#"
        if hash >= 0: line = line[..hash]
        line = line.trim
        if line.starts-with "nameserver ":
          server := line[11..].trim
          if net.IpAddress.is-valid server --accept-ipv4=true --accept-ipv6=false:
            nameservers.add server
      current-etc-resolv-client_ = DnsClient nameservers
  return current-etc-resolv-client_ or DEFAULT-CLIENT

ST-SIZE_ ::= 7
ST-MTIME_ ::= 9

stat_ name/string follow-links/bool -> List?:
  #primitive.file.stat

read-file-content-posix_ filename/string size/int -> ByteArray:
  #primitive.file.read-file-content-posix

CLASS-INTERNET ::= 1

RECORD-A       ::= 1
RECORD-CNAME   ::= 5
RECORD-AAAA    ::= 28  // IPv6 DNS lookup.

ERROR-NONE            ::= 0
ERROR-FORMAT          ::= 1
ERROR-SERVER-FAILURE  ::= 2
ERROR-NAME            ::= 3
ERROR-NOT-IMPLEMENTED ::= 4
ERROR-REFUSED         ::= 5

class DnsQuery_:
  id/int
  name/string
  accept-ipv4/bool
  accept-ipv6/bool
  query-packet/ByteArray

  constructor .name --.accept-ipv4 --.accept-ipv6:
    id = random 0x10000
    query-packet = create-query_ name id --accept-ipv4=accept-ipv4 --accept-ipv6=accept-ipv6

/**
A DnsClient contains a list of DNS servers in the form of IP addresses in
  string form.
The client starts by using the first DNS server in the list.
If a DNS server fails to answer after 2.5 times the $DNS-RETRY-TIMEOUT, then
  the client switches permanently to the next one on the list.
*/
class DnsClient:
  servers_/List
  current-server-index_/int := ?

  cache_ ::= Map  // From name to CacheEntry_.
  cache-ipv6_ ::= Map  // From name to CacheEntry_.

  /**
  Creates a DnsClient, given a list of DNS servers in the form of IP addresses
    in string form.
  */
  constructor servers/List:
    if servers.size == 0 or (servers.any: it is not string and it is not net.IpAddress): throw "INVALID_ARGUMENT"
    servers_ = servers.map: (it is string) ? net.IpAddress.parse it : it
    current-server-index_ = 0

  static DNS-UDP-PORT ::= 53

  get_ query/DnsQuery_ server-ip/net.IpAddress -> net.IpAddress:
    socket/udp-module.Socket? := null
    retry-timeout := DNS-RETRY-TIMEOUT
    attempt-counter := 1
    try:
      socket = udp-module.Socket

      socket.connect
        net.SocketAddress server-ip DNS-UDP-PORT

      // If we don't get an answer resend the query with exponential backoff
      // until the outer timeout expires or we have tried too many times.
      while true:
        socket.write query.query-packet
        ms := (Time.monotonic-us / 1000) % 1_000_000
        print "$(%3d ms / 1000).$(%03d ms % 1000): Write..."

        last-attempt := attempt-counter > MAX-RETRY-ATTEMPTS_
        catch --unwind=(: (not is-server-reachability-error_ it) or last-attempt):
          with-timeout retry-timeout:
            answer := socket.receive
            return decode-response_ query answer.data

        retry-timeout = retry-timeout * 1.5
        attempt-counter++
    finally:
      if socket: socket.close

  /**
  Look up a domain name and return an A or AAAA record.

  If given a numeric address like "127.0.0.1" it merely parses
    the numbers without a network round trip.
  */
  get name --accept-ipv4/bool=true --accept-ipv6/bool=false -> net.IpAddress
      --timeout/Duration=DNS-DEFAULT-TIMEOUT:
    if net.IpAddress.is-valid name --accept-ipv4=accept-ipv4 --accept-ipv6=accept-ipv6:
      return net.IpAddress.parse name
    if HOSTS_.contains name:
      return net.IpAddress.parse HOSTS_[name]

    hit := find-in-cache_ name --accept-ipv4=accept-ipv4 --accept-ipv6=accept-ipv6
    if hit: return hit

    query := DnsQuery_ name --accept-ipv4=accept-ipv4 --accept-ipv6=accept-ipv6

    with-timeout timeout:  // Typically a 20s timeout.
      // We try servers one at a time, but if there was a good error
      // message from one server (eg. no such domain) we let that
      // error unwind the stack and not try the next server.
      unwind-block := : | exception |
        not is-server-reachability-error_ exception
      while true:
        // Note that we continue to use the server that worked the last time
        // since we store the index in a field.
        current-server-ip := servers_[current-server-index_]

        trace := null
        catch --unwind=unwind-block:
          return get_ query current-server-ip

        // The current server didn't respond after about 3 seconds. Move to the next.
        current-server-index_ = (current-server-index_ + 1) % servers_.size
        print "Rotated to $servers_[current-server-index_]"
    unreachable

  static case-compare_ a/string b/string -> bool:
    if a == b: return true
    if a.size != b.size: return false
    a.size.repeat:
      ca := a[it]
      cb := b[it]
      if ca != cb:
        if not is-letter_ ca: return false
        if not is-letter_ cb: return false
        if ca | 0x20 != cb | 0x20: return false
    return true

  static is-letter_ c/int -> bool:
    return 'a' <= c <= 'z' or 'A' <= c <= 'Z'

  find-in-cache_ name --accept-ipv4/bool --accept-ipv6/bool -> net.IpAddress?:
    if accept-ipv4:
      if cache_.contains name:
        entry := cache_[name]
        if entry.valid: return entry.address
        cache_.remove name
    if accept-ipv6:
      if cache-ipv6_.contains name:
        entry := cache-ipv6_[name]
        if entry.valid: return entry.address
        cache-ipv6_.remove name
    return null

  static ERROR-MESSAGES_ ::= ["", "FORMAT_ERROR", "SERVER_FAILURE", "NO_SUCH_DOMAIN", "NOT_IMPLEMENTED", "REFUSED"]

  decode-response_ query/DnsQuery_ response/ByteArray -> net.IpAddress:
    received-id := BIG-ENDIAN.uint16 response 0
    if received-id != query.id:
      throw (DnsException "Response ID mismatch")
    // Check for expected response, but mask out the authoritative bit
    // so we can accept answers that are either authoritative or non-
    // authoritative.
    if response[2] & ~4 != 0x81: throw (DnsException "Unexpected response: $(%x response[2])")
    error := response[3] & 0xf
    if error != ERROR-NONE:
      detail := "error code $error"
      if 0 <= error < ERROR-MESSAGES_.size: detail = ERROR-MESSAGES_[error]
      throw (DnsException "Server responded: $detail" --name=query.name)
    position := 12
    queries := BIG-ENDIAN.uint16 response 4
    if queries != 1: throw (DnsException "Unexpected number of queries in response")
    q-name := decode-name response position: position = it
    position += 4
    if not case-compare_ q-name query.name:
      throw (DnsException "Response name mismatch")
    (BIG-ENDIAN.uint16 response 6).repeat:
      r-name := decode-name response position: position = it

      type := BIG-ENDIAN.uint16 response position
      position += 2

      clas := BIG-ENDIAN.uint16 response position
      position += 2
      if clas != CLASS-INTERNET: throw (DnsException "Unexpected response class: $clas")

      ttl := BIG-ENDIAN.int32 response position
      position += 4

      // We won't cache more than a day, even if the TTL is very high.  (In
      // practice TTLs over one hour are rare.)
      ttl = min ttl (3600 * 24)
      // Ignore negative TTLs.
      ttl = max 0 ttl

      rd-length := BIG-ENDIAN.uint16 response position
      position += 2
      if type == RECORD-A and query.accept-ipv4:
        if rd-length != 4: throw (DnsException "Unexpected IP address length $rd-length")
        if case-compare_ r-name q-name:
          result := net.IpAddress
              response.copy position position + 4
          if ttl > 0:
            trim-cache_ cache_
            cache_[query.name] = CacheEntry_ result ttl
          return result
        // Skip name that does not match.
      else if type == RECORD-AAAA and query.accept-ipv6:
        if rd-length != 16: throw (DnsException "Unexpected IP address length $rd-length")
        if case-compare_ r-name q-name:
          result := net.IpAddress
              response.copy position position + 16
          if ttl > 0:
            trim-cache_ cache-ipv6_
            cache-ipv6_[query.name] = CacheEntry_ result ttl
          return result
      else if type == RECORD-CNAME:
        q-name = decode-name response position: null
      position += rd-length
    throw (DnsException "Response did not contain matching A record" --name=query.name)

/**
Decodes a name from a DNS (RFC 1035) packet.
The block is invoked with the index of the next data in the packet.
*/
decode-name packet/ByteArray position/int [position-block] -> string:
  parts := []
  parts_ packet position parts position-block
  return parts.join "."

parts_ packet/ByteArray position/int parts/List [position-block] -> none:
  while packet[position] != 0:
    size := packet[position]
    if size <= 63:
      position++
      part := packet.to-string position position + size
      if part == "\0": throw (DnsException "Strange Samsung phone query detected")
      parts.add part
      position += size
    else:
      if size < 192: throw (DnsException "")
      pointer := (BIG-ENDIAN.uint16 packet position) & 0x3fff
      parts_ packet pointer parts: null
      position-block.call position + 2
      return
  position-block.call position + 1

/// Limits the size of the cache to avoid using too much memory.
trim-cache_ cache/Map -> none:
  if cache.size < MAX-CACHE-SIZE_: return

  // Cache too big.  Start by removing entries where the TTL has
  // expired.
  now := Time.monotonic-us
  cache.filter --in-place: | key value |
    value.end > now

  // Set the limit a bit lower now - we want to remove at least one third of
  // the entries when we trim the cache since it's an expensive operation.
  if cache.size < MAX-TRIMMED-CACHE-SIZE_: return

  // Remove every second entry.
  toggle := true
  cache.filter --in-place: | key value |
    toggle = not toggle
    toggle

class CacheEntry_:
  end / int                // Time in µs, compatible with Time.monotonic_us.
  address / net.IpAddress

  constructor .address ttl/int:
    end = Time.monotonic-us + ttl * 1_000_000

  valid -> bool:
    return Time.monotonic-us <= end

/**
Creates a UDP packet to look up the given name.
Regular DNS lookup is used, namely the A record for the domain.
The $query-id should be a 16 bit unsigned number which will be included in
  the reply.
*/
create-query_ name/string query-id/int --accept-ipv4/bool=true --accept-ipv6/bool=false -> ByteArray:
  if not (accept-ipv4 or accept-ipv6): throw "INVALID_ARGUMENT"
  query-count := (accept-ipv4 and accept-ipv6) ? 2 : 1
  parts := name.split "."
  length := 1
  parts.do: | part |
    if part.size > 63: throw (DnsException "DNS name parts cannot exceed 63 bytes" --name=name)
    if part.size < 1: throw (DnsException "DNS name parts cannot be empty" --name=name)
    part.do:
      if it == 0 or it == null: throw (DnsException "INVALID_DOMAIN_NAME" --name=name)
    length += part.size + 1
  query := ByteArray 10 + length + query-count * 6
  BIG-ENDIAN.put-uint16 query 0 query-id
  query[2] = 0x01  // Set RD bit.
  BIG-ENDIAN.put-uint16 query 4 query-count
  position := 12
  name-offset := position
  parts.do: | part |
    query[position++] = part.size
    query.replace position part
    position += part.size
  query[position++] = 0
  BIG-ENDIAN.put-uint16 query position     (accept-ipv4 ? RECORD-A : RECORD-AAAA)
  BIG-ENDIAN.put-uint16 query position + 2 CLASS-INTERNET
  position += 4
  if query-count == 2:
    // Point to the name from the first quety.
    BIG-ENDIAN.put-uint16 query position     0b1100_0000_0000_0000 + name-offset
    BIG-ENDIAN.put-uint16 query position + 2 RECORD-AAAA
    BIG-ENDIAN.put-uint16 query position + 4 CLASS-INTERNET
    position += 6
  assert: position == query.size
  return query

is-server-reachability-error_ error -> bool:
  return error == DEADLINE-EXCEEDED-ERROR or error is string and error.starts-with "A socket operation was attempted to an unreachable network"
