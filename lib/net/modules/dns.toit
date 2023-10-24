// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary show BIG-ENDIAN
import bytes show Buffer
import net.modules.udp as udp-module
import net

DNS-DEFAULT-TIMEOUT ::= Duration --s=20
DNS-RETRY-TIMEOUT ::= Duration --ms=600
MAX-RETRY-ATTEMPTS_ ::= 3
HOSTS_ ::= {"localhost": "127.0.0.1"}
MAX-CACHE-SIZE_ ::= platform == "FreeRTOS" ? 30 : 1000

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
Look up a domain name and return a single net.IpAddress.

See $dns-lookup-multi.
*/
dns-lookup -> net.IpAddress
    host/string
    --server/string?=null
    --client/DnsClient?=null
    --timeout/Duration=DNS-DEFAULT-TIMEOUT
    --accept-ipv4/bool=true
    --accept-ipv6/bool=false:

  return select-random-ip_ host
      dns-lookup-multi host
          --server=server
          --client=client
          --timeout=timeout
          --accept-ipv4=accept-ipv4
          --accept-ipv6=accept-ipv6

/**
Look up a domain name and return a list of net.IpAddress records.

If given a numeric address like 127.0.0.1 it merely parses
  the numbers without a network round trip.

By default the server is determined by the network interface.  The fallback
  servers if none are configured are the Google and Cloudflare DNS services.

If there are multiple servers then they are tried in rotation until one
  responds.  If one responds with an error (eg. no such domain) we do not try
  the next one.  This is in line with the way that Linux handles multiple
  servers on the same lookup request.
*/
dns-lookup-multi -> List
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
  types := {}
  if accept-ipv4: types.add RECORD-A
  if accept-ipv6: types.add RECORD-AAAA
  return client.get_ host --record-types=types --timeout=timeout

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
RECORD-PTR     ::= 12
RECORD-TXT     ::= 16
RECORD-SRV     ::= 33
RECORD-AAAA    ::= 28  // IPv6 DNS lookup.
RECORD-ANY     ::= 255

QTYPE-NAMES ::= {
    1: "A",
    5: "CNAME",
    12: "PTR",
    16: "TXT",
    28: "AAAA",
    33: "SRV",
    255: "ANY",
}

ERROR-NONE            ::= 0
ERROR-FORMAT          ::= 1
ERROR-SERVER-FAILURE  ::= 2
ERROR-NAME            ::= 3
ERROR-NOT-IMPLEMENTED ::= 4
ERROR-REFUSED         ::= 5

ERROR-NAMES ::= {
    0: "NONE",
    1: "FORMAT_ERROR",
    2: "SERVER_FAILURE",
    3: "NO_SUCH_DOMAIN",
    4: "NOT_IMPLEMENTED",
    5: "REFUSED",
}

class DnsQuery_:
  base-id/int
  name/string
  query-packets/Map  // From record type (int) to packet (ByteArray).

  constructor .name --record-types/Set:
    base-id = random 0x10000
    query-packets = Map
    id-offset := 0
    // According to the RFC you can put several queries of different types in
    // the same packet, but actually nobody really supports that, so we create
    // two different query packets, for IPv4 and IPv6 and send them at the same
    // time.
    record-types.do: | type |
      query-packets[type] = create-query_ name ((base-id + id-offset++) & 0xffff) type

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

  cache_ ::= Map  // From numeric q-type to (Map name to CacheEntry_).

  /**
  Creates a DnsClient, given a list of DNS servers in the form of IP addresses
    in string form.
  */
  constructor servers/List:
    if servers.size == 0 or (servers.any: it is not string and it is not net.IpAddress): throw "INVALID_ARGUMENT"
    servers_ = servers.map: (it is string) ? net.IpAddress.parse it : it
    current-server-index_ = 0

  static DNS-UDP-PORT ::= 53

  fetch_ query/DnsQuery_ server-ip/net.IpAddress -> List:
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
        // Write both packets (IPv4 and IPv6) to the socket, wait for the
        // first response.
        query.query-packets.do: | type packet |
          socket.write packet

        last-attempt := attempt-counter > MAX-RETRY-ATTEMPTS_
        catch --unwind=(: (not is-server-reachability-error_ it) or last-attempt):
          with-timeout retry-timeout:
            // Expect to get as many answers as we sent queries.
            remaining-tries := query.query-packets.size
            while remaining-tries != 0:
              answer := socket.receive
              result := decode-and-cache-response_ query answer.data
              if result:
                remaining-tries--
                if remaining-tries == 0 or result.size != 0: return result
            throw (DnsException "No response from server" --name=query.name)

        retry-timeout = retry-timeout * 1.5
        attempt-counter++
    finally:
      if socket: socket.close

  /**
  Look up a domain name and return a list of results.
  The $record-type argument can be $RECORD-A, or $RECORD-AAAA, in which case the result
    is a list of $net.IpAddress.
  If the $record-type is $RECORD-TXT, $RECORD-PTR, or $RECORD-CNAME the results
    will be strings.
  If the $record-type is $RECORD-SRV, the results are instances of $SrvResource
    (normally only used for mDNS).
  */
  get name -> List
      --record-type/int
      --timeout/Duration=DNS-DEFAULT-TIMEOUT:
    list := get_ name --record-types={record-type} --timeout=timeout
    if not list: throw (DnsException "No record found" --name=name)
    return list

  /**
  Look up a domain name and return an A or AAAA record.

  If given a numeric address like "127.0.0.1" it merely parses
    the numbers without a network round trip.
  */
  get name -> net.IpAddress
      --accept-ipv4/bool=true
      --accept-ipv6/bool=false
      --timeout/Duration=DNS-DEFAULT-TIMEOUT:
    types := {}
    if accept-ipv4: types.add RECORD-A
    if accept-ipv6: types.add RECORD-AAAA
    return select-random-ip_ name
        get_ name --record-types=types --timeout=timeout

  get_ name -> List
      --record-types/Set
      --timeout/Duration=DNS-DEFAULT-TIMEOUT:

    if net.IpAddress.is-valid name
        --accept-ipv4 = record-types.contains RECORD-A
        --accept-ipv6 = record-types.contains RECORD-AAAA:
      return [net.IpAddress.parse name]

    record-types.do: | record-type |
      HOSTS_.get name --if-present=: | text |
        address := net.IpAddress.parse text
        if address.is-ipv6 == (record-type == RECORD-AAAA): return [address]

      result := find-in-cache cache_ name record-type
      if result: return result

    query := DnsQuery_ name --record-types=record-types

    with-timeout timeout:  // Typically a 20s timeout.
      // We try servers one at a time, but if there was a good error
      // message from one server (eg. no such domain) we let that
      // error unwind the stack and do not try the next server.
      unwind-block := : | exception |
        not is-server-reachability-error_ exception
      while true:
        // Note that we continue to use the server that worked the last time
        // since we store the index in a field.
        current-server-ip := servers_[current-server-index_]

        trace := null
        catch --unwind=unwind-block:
          return fetch_ query current-server-ip

        // The current server didn't respond after about 3 seconds. Move to the next.
        current-server-index_ = (current-server-index_ + 1) % servers_.size
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

  /**
  This is just for regular DNS A and AAAA responses, it doesn't decode queries
    and the more funky record types needed for mDNS.
  */
  decode-and-cache-response_ query/DnsQuery_ response/ByteArray -> List?:
    decoded := decode-packet response --error-name=query.name

    // Check for expected response, but mask out the authoritative bit
    // and the recursion available bit, which we do not care about.
    if decoded.status_bits & ~0x480 != 0x8100:
      protocol-error_  // Unexpected response flags.

    id := query.base-id
    expected-type/int? := null
    query.query-packets.do: | type p |
      if decoded.id == id:
        expected-type = type
      id = (id + 1) & 0xffff
    // Id did not match or otherwise useless response.
    if expected-type == null or decoded.questions.size != 1: return null
    decoded-question/Question := decoded.questions[0] as Question

    if not case-compare_ decoded-question.name query.name:
      // Suspicious that the id matched, but the name didn't.
      // Possible DNS poisoning attack.
      throw (DnsException "Response name mismatch")

    // Simplified list of answers for the caller.
    answers := []

    relevant-name := decoded-question.name

    ttl := int.MAX

    // Since we sent a single question we expect answers that start with a
    // repeat of that question and then just contain data for that one
    // question.
    decoded.resources.do: | resource |
      if resource.type == expected-type:
        if resource.name != relevant-name: continue.do
        if resource is StringResource:
          answers.add (resource as StringResource).value
        else if resource is AResource:
          answers.add (resource as AResource).address
        else:
          answers.add (resource as SrvResource)
        ttl = min ttl resource.ttl
      else if resource.type == RECORD-CNAME:
        relevant-name = (resource as StringResource).value

    // We won't cache more than a day, even if the TTL is very high.  (In
    // practice TTLs over one hour are rare.)
    ttl = min ttl (3600 * 24)
    // Ignore negative TTLs and very short TTLs.
    ttl = max 10 ttl

    if answers.size > 0 and ttl > 0:
      trim-cache cache_ expected-type
      type-cache := cache_.get expected-type --init=: {:}
      type-cache[query.name] = CacheEntry_ answers ttl
    return answers

protocol-error_ -> none:
  throw (DnsException "DNS protocol error")
  unreachable

/**
Creates a UDP packet to look up the given name.
Regular DNS lookup is used, namely the A record for the domain.
The $query-id should be a 16 bit unsigned number which will be included in
  the reply.
This is a light-weight version of create-dns-packet for applications that
  are only looking up regular names and don't need advanced DNS features
  like the ones used by mDNS.
*/
create-query_ name/string query-id/int record-type/int -> ByteArray:
  result := Buffer
  result.write-int16-big-endian query-id
  result.write #[
    1, 0,  // Set RD bit.
    0, 1,  // One query.
    0, 0,  // No answers
    0, 0,  // No authorities
    0, 0,  // No additional
  ]
  write-name_ name --locations=null --buffer=result
  result.write-int16-big-endian record-type
  result.write-int16-big-endian CLASS-INTERNET
  return result.bytes

select-random-ip_ name/string list/List -> net.IpAddress:
  if list and list.size > 0:
    return list[random list.size]  // Randomize which of the IP's we return.
  throw (DnsException "No name record found" --name=name)

is-server-reachability-error_ error -> bool:
  return error == DEADLINE-EXCEEDED-ERROR or error is string and error.starts-with "A socket operation was attempted to an unreachable network"

/**
Returns a list of results for the given name and type, or null if the
  cache does not contain a valid entry (or it has expired).
*/
find-in-cache top-cache/Map name type/int -> List?:
  map := top-cache.get type --if-absent=: return null
  entry := map.get name --if-absent=: return null
  if entry.valid:
    return entry.value
  map.remove name
  return null

/**
Decodes a DNS packet.
The $error-name is only used for error messages.
*/
decode-packet packet/ByteArray --error-name/string?=null -> DecodedPacket:
  response := packet
  received-id    := BIG-ENDIAN.uint16 response 0
  status-bits    := BIG-ENDIAN.uint16 response 2
  queries        := BIG-ENDIAN.uint16 response 4
  response-count := BIG-ENDIAN.uint16 response 6
  // Ignore NSCOUNT and ANCOUNT at 8 and 10.

  error := status-bits & 0xf
  if error != ERROR-NONE:
    detail := ERROR-NAMES.get error --if-absent=: "error code $error"
    throw (DnsException "Server responded: $detail" --name=error-name)
  position := 12

  result := DecodedPacket --id=received-id --status-bits=status-bits

  queries.repeat:
    q-name := decode-name response position: position = it
    q-type := BIG-ENDIAN.uint16 response position
    q-class := BIG-ENDIAN.uint16 response position + 2
    position += 4
    unicast-ok := q-class & 0x8000 != 0
    if q-class & 0x7fff != CLASS-INTERNET: protocol-error_  // Unexpected response class.

    result.questions.add
        Question q-name q-type --unicast-ok=unicast-ok

  response-count.repeat:
    r-name := decode-name response position: position = it
    clas := BIG-ENDIAN.uint16 response (position + 2)
    type := BIG-ENDIAN.uint16 response position
    ttl  := BIG-ENDIAN.int32 response (position + 4)
    rd-length := BIG-ENDIAN.uint16 response (position + 8)
    position += 10

    flush := clas & 0x8000 != 0
    if clas & 0x7fff != CLASS-INTERNET: protocol-error_  // Unexpected response class.

    if type == RECORD-A or type == RECORD-AAAA:
      length := type == RECORD-A ? 4 : 16
      if rd-length != length: protocol-error_  // Unexpected IP address length.
      result.resources.add
          AResource r-name type ttl flush
              net.IpAddress
                  response.copy position position + length
    else if type == RECORD-PTR or type == RECORD-CNAME:
      result.resources.add
          StringResource r-name type ttl flush
              decode-name response position: null
    else if type == RECORD-TXT:
      length := response[position]
      if rd-length < length + 1: protocol-error_  // Unexpected TXT length.
      value := response[position + 1..position + 1 + length].to-string
      result.resources.add
          StringResource r-name type ttl flush value
    else if type == RECORD-SRV:
      priority := BIG-ENDIAN.uint16 response position
      weight := BIG-ENDIAN.uint16 response (position + 2)
      port := BIG-ENDIAN.uint16 response (position + 4)
      length := response[position + 6]
      value := response[position + 7..position + 7 + length].to-string
      result.resources.add
          SrvResource r-name type ttl flush value priority weight port
    position += rd-length

  return result

class CacheEntry_:
  end / int                // Time in µs, compatible with Time.monotonic-us.
  value / List

  constructor .value ttl/int:
    end = Time.monotonic-us + ttl * 1_000_000

  valid -> bool:
    return Time.monotonic-us <= end

/// Limits the size of the cache to avoid using too much memory.
trim-cache top-cache/Map type/int --max-cache-size/int=MAX-CACHE-SIZE_ -> none:
  cache := top-cache.get type --if-absent=: return
  if cache.size < max-cache-size: return

  // Cache too big.  Start by removing entries where the TTL has
  // expired.
  now := Time.monotonic-us
  cache.filter --in-place: | key/string value/CacheEntry_ |
    value.end > now

  // Set the limit a bit lower now - we want to remove at least one third of
  // the entries when we trim the cache since it's an expensive operation.
  max-trimmed-cache-size := max-cache-size * 2 / 3
  if cache.size < max-trimmed-cache-size: return

  // Remove every second entry.
  toggle := true
  cache.filter --in-place: | key value |
    toggle = not toggle
    toggle

class DecodedPacket:
  id/int
  status_bits/int
  questions/List := []
  resources/List := []

  constructor --.id --.status-bits:
    if status-bits & 0x6070 != 0 or opcode > 2:
      protocol-error_  // Unexpected flags in response.

  is-response -> bool:
    return status-bits & 0x8000 != 0

  is-authoritative -> bool:
    return status-bits & 0x0400 != 0

  is-truncated -> bool:
    return status-bits & 0x0200 != 0

  is-recursion-desired -> bool:
    return status-bits & 0x0100 != 0

  is-recursion-available -> bool:
    return status-bits & 0x0080 != 0

  error-code -> int:
    return status-bits & 0x000F

  opcode -> int:
    return (status-bits & 0x7800) >> 11

class Question:
  name/string
  type/int
  unicast-ok/bool

  constructor .name/string .type/int --.unicast-ok=false:

class Resource:
  name/string
  type/int
  ttl/int
  flush/bool

  constructor .name/string .type/int .ttl .flush:

class AResource extends Resource:
  address/net.IpAddress

  constructor name/string type/int ttl/int flush/bool .address:
    super name type ttl flush

  constructor name/string ttl/int .address/net.IpAddress --flush/bool=false:
    super name (address.is-ipv6 ? RECORD-AAAA : RECORD-A) ttl flush

class StringResource extends Resource:
  value/string

  constructor name/string type/int ttl/int flush/bool .value:
    super name type ttl flush

  is-cname -> bool:
    return type == RECORD-CNAME

  is-ptr -> bool:
    return type == RECORD-PTR

  is-txt -> bool:
    return type == RECORD-TXT

class SrvResource extends StringResource:
  priority/int
  weight/int
  port/int

  constructor name/string type/int ttl/int flush/bool value/string .priority .weight .port:
    super name type ttl flush value

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
      if size < 192: protocol-error_
      pointer := (BIG-ENDIAN.uint16 packet position) & 0x3fff
      parts_ packet pointer parts: null
      position-block.call position + 2
      return
  position-block.call position + 1

/**
Create a DNS packet for lookups or reponses.
*/
create-dns-packet queries/List records/List -> ByteArray
    --id/int
    --is-response/bool
    --is-authoritative/bool=false:

  previous-locations := {:}

  result := Buffer

  status-bits := is-response ? 0x8000 : 0x0000
  if is-authoritative: status-bits |= 0x0400

  result.write-int16-big-endian id
  result.write-int16-big-endian status-bits
  result.write-int16-big-endian queries.size
  result.write-int16-big-endian records.size
  result.write-int32-big-endian 0  // Don't support the other things.

  queries.do: | query/Question |
    write-name_ query.name --locations=previous-locations --buffer=result
    result.write-int16-big-endian query.type
    clas := CLASS-INTERNET + (query.unicast-ok ? 0x8000 : 0)
    result.write-int16-big-endian clas
  records.do: | record/Resource |
    write-name_ record.name --locations=previous-locations --buffer=result
    type := record.type
    result.write-int16-big-endian type
    clas := CLASS-INTERNET + (record.flush ? 0x8000 : 0)
    result.write-int16-big-endian clas
    result.write-int32-big-endian record.ttl
    if record is AResource:
      bytes := (record as AResource).address.raw
      result.write-int16-big-endian bytes.size
      result.write bytes
    else if type == RECORD-CNAME or type == RECORD-PTR:
      str := (record as StringResource).value
      length := write-name_ str --locations=previous-locations --buffer=null
      result.write-int16-big-endian length
      write-name_ str --locations=previous-locations --buffer=result
    else if type == RECORD-TXT:
      str := (record as StringResource).value
      if str.size > 255: throw (DnsException "TXT records cannot exceed 255 bytes" --name=str)
      result.write-int16-big-endian str.size
      result.write str
    else if record is SrvResource:
      srv := record as SrvResource
      str := srv.value
      if str.size > 255: throw (DnsException "SRV records cannot exceed 255 bytes" --name=str)
      result.write-int16-big-endian (str.size + 7)
      result.write-int16-big-endian srv.priority
      result.write-int16-big-endian srv.weight
      result.write-int16-big-endian srv.port
      result.write-byte str.size
      result.write str
    else:
      throw "Unknown record type: $record"
  return result.bytes

write-name_ name/string --locations/Map? --buffer/Buffer? -> int:
  parts := name.split "."
  length := 1
  pos := 0
  parts.do: | part/string |
    if part.size > 63: throw (DnsException "DNS name parts cannot exceed 63 bytes" --name=name)
    if part.size < 1: throw (DnsException "DNS name parts cannot be empty" --name=name)
    tail := name[pos..]
    pos += part.size + 1
    if locations:
      locations.get tail --if-present=: | location/int |
        if buffer: buffer.write-int16-big-endian location + 0xc000
        length += 2
        return length
    if buffer:
      if locations: locations[tail] = buffer.size
      buffer.write-byte part.size
      buffer.write part
    length += part.size + 1
  if buffer: buffer.write-byte 0
  return length

