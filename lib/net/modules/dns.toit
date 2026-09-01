// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import net
import net.udp
import system
import system show platform

DNS-DEFAULT-TIMEOUT ::= Duration --s=20
DNS-RETRY-TIMEOUT ::= Duration --ms=600
MAX-RETRY-ATTEMPTS_ ::= 3
HOSTS_ ::= {"localhost": "127.0.0.1"}
MAX-CACHE-SIZE_ ::= platform == system.PLATFORM-FREERTOS ? 30 : 1000

MDNS-MULTICAST-ADDRESS_ ::= net.IpAddress.parse "224.0.0.251"
MDNS-PORT_ ::= 5353


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
    --network/udp.Interface
    --server/string?=null
    --client/DnsClient?=null
    --timeout/Duration=DNS-DEFAULT-TIMEOUT
    --accept-ipv4/bool=true
    --accept-ipv6/bool=false:

  return select-random-ip_ host
      dns-lookup-multi host
          --network=network
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
  If we are looking up a name ending in ".local" and no specific client is provided,
  we use the default mDNS client $default-mdns-client.
*/
dns-lookup-multi -> List
    host/string
    --network/udp.Interface
    --server/string?=null
    --client/DnsClient?=null
    --timeout/Duration=DNS-DEFAULT-TIMEOUT
    --accept-ipv4/bool=true
    --accept-ipv6/bool=false:
  if server and client: throw "INVALID_ARGUMENT"
  if not client:
    if host.ends-with ".local":
      client = default-mdns-client
    else if not server:
      client = default-client
    else:
      client = AUTO-CREATED-CLIENTS_.get server --init=:
        DnsClient [server]
  types := {}
  if accept-ipv4: types.add RECORD-A
  if accept-ipv6: types.add RECORD-AAAA
  return client.get_ host
      --record-types=types
      --network=network
      --timeout=timeout

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

default-mdns-client_/DnsClient? := null

/**
The default mDNS client.

By default this is an instance of $MdnsDnsClient, but it can be overwritten
  with $(default-mdns-client= client).
*/
default-mdns-client -> DnsClient:
  if not default-mdns-client_: default-mdns-client_ = DnsClient.mdns
  return default-mdns-client_

default-mdns-client= client/DnsClient -> none:
  default-mdns-client_ = client

RESOLV-CONF_ ::= "/etc/resolv.conf"

/**
On Unix systems the default client is one that keeps an eye on changes in
  /etc/resolv.conf.
On FreeRTOS systems the default client is set by DHCP.
On Windows defaults to using Google and Cloudflare DNS servers.
On all platforms you can set a custom default client with the
  $(default-client= client) setter.
*/
default-client -> DnsClient:
  if user-set-client_: return user-set-client_
  if platform == system.PLATFORM-FREERTOS and dhcp-client_: return dhcp-client_
  if platform == system.PLATFORM-LINUX or platform == system.PLATFORM-MACOS: return etc-resolv-client_
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
abstract class DnsClient:
  cache_ ::= Map  // From numeric q-type to (Map name to CacheEntry_).

  constructor servers/List:
    return DnsClient_ servers

  constructor.mdns:
    return MdnsDnsClient

  constructor.private_:
    cache_ = Map

  /**
  Look up a domain name and return a list of results.
  The $record-type argument can be $RECORD-A, or $RECORD-AAAA, in which case the result is a list of $net.IpAddress.
  If the $record-type is $RECORD-TXT, $RECORD-PTR, or $RECORD-CNAME the results will be strings.
  If the $record-type is $RECORD-SRV, the results are instances of $SrvResource (normally only used for mDNS).
  */
  get name -> List
      --record-type/int
      --network/udp.Interface
      --timeout/Duration=DNS-DEFAULT-TIMEOUT:
    list := get_ name
        --record-types={record-type}
        --network=network
        --timeout=timeout
    return list

  /**
  Look up a domain name and return an A or AAAA record.

  If given a numeric address like "127.0.0.1" it merely parses
    the numbers without a network round trip.
  */
  get name -> net.IpAddress
      --network/udp.Interface
      --accept-ipv4/bool=true
      --accept-ipv6/bool=false
      --timeout/Duration=DNS-DEFAULT-TIMEOUT:
    types := {}
    if accept-ipv4: types.add RECORD-A
    if accept-ipv6: types.add RECORD-AAAA
    return select-random-ip_ name
        get_ name --record-types=types --network=network --timeout=timeout

  get_ name -> List
      --record-types/Set
      --network/udp.Interface
      --timeout/Duration=DNS-DEFAULT-TIMEOUT:

    if record-types.is-empty: return []

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

    // We try servers one at a time, but if there was a good error
    // message from one server (eg. no such domain) we let that
    // error unwind the stack and do not try the next server.
    unwind-block := : | exception |
      not is-server-reachability-error_ exception

    with-timeout timeout:  // Typically a 20s timeout.
      while true:
        catch --unwind=unwind-block:
          return fetch_ query --network=network
    unreachable

  abstract fetch_ query/DnsQuery_ --network/udp.Interface -> List

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
  decode-and-cache-response_ query/DnsQuery_ response/ByteArray --mdns/bool=false -> List?:
    decoded := decode-packet response --error-name=query.name

    // Check for expected response, but mask out the authoritative bit
    // and the recursion available bit, which we do not care about.
    // The recursion desired bit seems to vary randomly, so we ignore
    // that too.
    if decoded.status-bits & ~0x580 != 0x8000 and not mdns:
      protocol-error_  // Unexpected response flags.

    id := query.base-id
    expected-type/int? := null
    query.query-packets.do: | type p |
      if decoded.id == id:
        expected-type = type
      id = (id + 1) & 0xffff
    // Id did not match or otherwise useless response.
    if not mdns:
      if expected-type == null: return null
      if decoded.questions.size != 1: return null

    if decoded.questions.size == 1:
      decoded-question/Question := decoded.questions[0] as Question

      if not case-compare_ decoded-question.name query.name:
        // Suspicious that the id matched, but the name didn't.
        // Possible DNS poisoning attack.
        if not mdns: throw (DnsException "Response name mismatch")
        return null

    // Simplified list of answers for the caller.
    answers := []

    // We collect answers by type so we can cache them properly.
    // Map from type (int) to List of answers.
    answers-by-type := {:}
    // Map from type (int) to min TTL (int).
    ttl-by-type := {:}

    relevant-name := query.name

    // Since we sent a single question we expect answers that start with a
    // repeat of that question and then just contain data for that one
    // question.
    decoded.resources.do: | resource |
      type := resource.type
      type-matches := false
      if type == expected-type:
        type-matches = true
      else if not expected-type and mdns:
        // If we didn't match the ID, and we are in mDNS mode, we accept
        // any response that matches one of the types we are looking for.
        type-matches = query.query-packets.contains type

      if type-matches:
        if resource.name != relevant-name: continue.do

        entry := null
        if resource is SrvResource:
          entry = (resource as SrvResource)
        else if resource is StringResource:
          entry = (resource as StringResource).value
        else if resource is AResource:
          entry = (resource as AResource).address

        if entry:
          list := answers-by-type.get type --init=(: [])
          list.add entry

          current-ttl := ttl-by-type.get type --if-absent=(: int.MAX)
          ttl-by-type[type] = min current-ttl resource.ttl

      else if resource.type == RECORD-CNAME:
        relevant-name = (resource as StringResource).value

    answers-by-type.do: | type list |
      ttl := ttl-by-type[type]
      // We won't cache more than a day, even if the TTL is very high.  (In
      // practice TTLs over one hour are rare.)
      ttl = min ttl (3600 * 24)
      // Ignore negative TTLs and very short TTLs.
      ttl = max 10 ttl

      if list.size > 0 and ttl > 0:
        trim-cache cache_ type
        type-cache := cache_.get type --init=: {:}
        type-cache[query.name] = CacheEntry_ list ttl
        answers.add-all list

    return answers


  fetch-loop_ query/DnsQuery_ socket/udp.Socket --mdns/bool=false [--do-send] [--on-timeout] -> List:
    retry-timeout := DNS-RETRY-TIMEOUT
    attempt-counter := 1
    while true:
      // Send packets.
      do-send.call

      last-attempt := attempt-counter > MAX-RETRY-ATTEMPTS_
      e := catch --unwind=(: (not is-server-reachability-error_ it) or last-attempt):
        with-timeout retry-timeout:
          // Expect to get as many answers as we sent queries.
          remaining-tries := query.query-packets.size
          while remaining-tries != 0:
            answer := socket.receive
            // mDNS responses might not match the query ID (e.g. unsolicited responses).
            // We pass the mdns flag to allow relaxed ID checking.
            result := decode-and-cache-response_ query answer.data --mdns=mdns
            if result:
              remaining-tries--
              if remaining-tries == 0 or result.size != 0: return result

          // We only reach this point if we didn't send any queries.
          // Otherwise the loop runs until we have all answers, or until the
          // timeout interrupts us.
          unreachable

      assert: is-server-reachability-error_ e
      on-timeout.call

      retry-timeout = retry-timeout * 1.5
      attempt-counter++
    unreachable

class DnsClient_ extends DnsClient:
  servers_/List
  current-server-index_/int := ?

  /**
  Creates a DnsClient, given a list of DNS servers in the form of IP addresses
    in string form.
  */
  constructor servers/List:
    if servers.size == 0 or (servers.any: it is not string and it is not net.IpAddress and it is not net.SocketAddress): throw "INVALID_ARGUMENT"
    servers_ = servers.map:
      if it is string:
        ip := net.IpAddress.parse it
        net.SocketAddress ip DNS-UDP-PORT
      else if it is net.IpAddress:
        net.SocketAddress it DNS-UDP-PORT
      else: it
    current-server-index_ = 0
    super.private_

  static DNS-UDP-PORT ::= 53

  fetch_ query/DnsQuery_ --network/udp.Interface -> List:
    socket/udp.Socket? := null
    // Note that we continue to use the server that worked the last time
    // since we store the index in a field.
    server-addr := servers_[current-server-index_]
    try:
      socket = network.udp-open
      error := catch: socket.connect server-addr
      if error:
        if is-server-reachability-error_ error:
          // The current server didn't respond (or was unreachable). Move to the next.
          current-server-index_ = (current-server-index_ + 1) % servers_.size
        throw error

      return fetch-loop_ query socket --no-mdns
          --do-send=:
            query.query-packets.do: | type packet |
              socket.write packet
          --on-timeout=:
            // The current server didn't respond after about 3 seconds. Move to the next.
            current-server-index_ = (current-server-index_ + 1) % servers_.size
            server-addr = servers_[current-server-index_]
            // We reconnect the socket, as the server we are sending to has changed.
            socket.connect server-addr

    finally:
      if socket: socket.close

class MdnsDnsClient extends DnsClient:
  address_/net.IpAddress
  port_/int

  constructor --address/net.IpAddress=MDNS-MULTICAST-ADDRESS_ --port/int=MDNS-PORT_:
    address_ = address
    port_ = port
    super.private_

  fetch_ query/DnsQuery_ --network/udp.Interface -> List:
    socket/udp.Socket? := null
    // Recreate the query packets with the QU bit set.
    // We modify the query in place. This is fine because the query object is
    // created for this specific lookup request (in `get_`) and is not shared.
    // If the lookup is retried (e.g. because of a timeout), we want to reuse
    // the modified query object (with the QU bit set) anyway.
    query.query-packets.map --in-place: | type packet |
      create-query_ query.name query.base-id type --unicast-response

    try:
      // Open a UDP socket. We don't join the multicast group, but we send to it.
      socket = network.udp-open

      // Connecting a UDP socket filters incoming packets to be only from the connected peer.
      // mDNS responders send unicast responses to the source port.
      // We do not connect, as that would filter out the unicast responses we expect.

      address := net.SocketAddress address_ port_

      return fetch-loop_ query socket --mdns
          --do-send=:
            // Send block.
            query.query-packets.do: | type packet |
              socket.send (udp.Datagram packet address)
          --on-timeout=:
    finally:
      if socket: socket.close

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
create-query_ name/string query-id/int record-type/int --unicast-response/bool=false -> ByteArray:
  result := io.Buffer
  result.big-endian.write-int16 query-id
  result.write #[
    1, 0,  // Set RD bit.
    0, 1,  // One query.
    0, 0,  // No answers
    0, 0,  // No authorities
    0, 0,  // No additional
  ]
  write-name_ name --locations=null --buffer=result
  result.big-endian.write-int16 record-type
  clas := CLASS-INTERNET
  if unicast-response: clas |= 0x8000
  result.big-endian.write-int16 clas
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
  reader := io.Reader response
  received-id    := reader.big-endian.read-uint16
  status-bits    := reader.big-endian.read-uint16
  queries        := reader.big-endian.read-uint16
  response-count := reader.big-endian.read-uint16
  // Ignore NSCOUNT and ANCOUNT at 8 and 10.
  reader.skip 4

  error := status-bits & 0xf
  if error != ERROR-NONE:
    detail := ERROR-NAMES.get error --if-absent=: "error code $error"
    throw (DnsException "Server responded: $detail" --name=error-name)

  result := DecodedPacket --id=received-id --status-bits=status-bits

  queries.repeat:
    q-name := decode-name reader response
    q-type := reader.big-endian.read-uint16
    q-class := reader.big-endian.read-uint16
    unicast-ok := q-class & 0x8000 != 0
    if q-class & 0x7fff != CLASS-INTERNET: protocol-error_  // Unexpected response class.

    result.questions.add
        Question q-name q-type --unicast-ok=unicast-ok

  response-count.repeat:
    r-name := decode-name reader response
    type := reader.big-endian.read-uint16
    clas := reader.big-endian.read-uint16
    ttl  := reader.big-endian.read-int32
    rd-length := reader.big-endian.read-uint16

    flush := clas & 0x8000 != 0
    if clas & 0x7fff != CLASS-INTERNET: protocol-error_  // Unexpected response class.

    read-before-record := reader.processed
    if type == RECORD-A or type == RECORD-AAAA:
      length := type == RECORD-A ? 4 : 16
      if rd-length != length: protocol-error_  // Unexpected IP address length.
      result.resources.add
          AResource r-name type ttl flush
              net.IpAddress
                  reader.read-bytes length
    else if type == RECORD-PTR or type == RECORD-CNAME:
      result.resources.add
          StringResource r-name type ttl flush
              decode-name reader response
    else if type == RECORD-TXT:
      length := reader.read-byte
      if rd-length < length + 1: protocol-error_  // Unexpected TXT length.
      value := reader.read-string length
      result.resources.add
          StringResource r-name type ttl flush value
    else if type == RECORD-SRV:
      priority := reader.big-endian.read-uint16
      weight := reader.big-endian.read-uint16
      port := reader.big-endian.read-uint16
      value := decode-name reader response
      result.resources.add
          SrvResource r-name type ttl flush value priority weight port
    read-after-record := reader.processed
    // Skip the rest of the record if it wasn't consumed.
    reader.skip (rd-length - (read-after-record - read-before-record))

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

Deprecated. Use $(decode-name reader packet) instead.
*/
decode-name packet/ByteArray position/int [position-block] -> string:
  reader := io.Reader packet[position..]
  result := decode-name reader packet
  position-block.call (position + reader.processed)
  return result

/**
Decodes a name from a DNS (RFC 1035) packet.

Takes both the $reader and the $packet, as the parts can contain
  pointers that are absolute in the packet.
*/
decode-name reader/io.Reader packet/ByteArray -> string:
  parts := []
  parts_ reader packet parts
  return parts.join "."

parts_ reader/io.Reader packet/ByteArray parts/List -> none:
  while true:
    size := reader.peek-byte
    if size == 0: break
    if size <= 63:
      reader.read-byte
      part := reader.read-string size
      if part == "\0": throw (DnsException "Strange Samsung phone query detected")
      parts.add part
    else:
      if size < 192: protocol-error_
      pointer := reader.big-endian.read-uint16 & 0x3fff
      parts_ (io.Reader packet[pointer..]) packet parts
      return
  reader.read-byte

/**
Create a DNS packet for lookups or reponses.
*/
create-dns-packet queries/List records/List -> ByteArray
    --id/int
    --is-response/bool
    --is-authoritative/bool=false:

  previous-locations := {:}

  result := io.Buffer

  status-bits := is-response ? 0x8000 : 0x0000
  if is-authoritative: status-bits |= 0x0400

  result-be := result.big-endian
  result-be.write-int16 id
  result-be.write-int16 status-bits
  result-be.write-int16 queries.size
  result-be.write-int16 records.size
  result-be.write-int32 0  // Don't support the other things.

  queries.do: | query/Question |
    write-name_ query.name --locations=previous-locations --buffer=result
    result-be.write-int16 query.type
    clas := CLASS-INTERNET + (query.unicast-ok ? 0x8000 : 0)
    result-be.write-int16 clas
  records.do: | record/Resource |
    write-name_ record.name --locations=previous-locations --buffer=result
    type := record.type
    result-be.write-int16 type
    clas := CLASS-INTERNET + (record.flush ? 0x8000 : 0)
    result-be.write-int16 clas
    result-be.write-int32 record.ttl
    if record is AResource:
      bytes := (record as AResource).address.raw
      result-be.write-int16 bytes.size
      result.write bytes
    else if type == RECORD-CNAME or type == RECORD-PTR:
      str := (record as StringResource).value
      length := write-name_ str --locations=previous-locations --buffer=null
      result-be.write-int16 length
      write-name_ str --locations=previous-locations --buffer=result
    else if type == RECORD-TXT:
      str := (record as StringResource).value
      if str.size > 255: throw (DnsException "TXT records cannot exceed 255 bytes" --name=str)
      result-be.write-int16 (str.size + 1)
      result.write-byte str.size
      result.write str
    else if record is SrvResource:
      srv := record as SrvResource
      str := srv.value
      // Calculate length of domain name part
      name-length := write-name_ str --locations=previous-locations --buffer=null
      result-be.write-int16 (6 + name-length)
      result-be.write-int16 srv.priority
      result-be.write-int16 srv.weight
      result-be.write-int16 srv.port
      write-name_ str --locations=previous-locations --buffer=result
    else:
      throw "Unknown record type: $record"
  return result.bytes

write-name_ name/string --locations/Map? --buffer/io.Buffer? -> int:
  parts := name.split "."
  length := 0
  pos := 0
  parts.do: | part/string |
    if part.size > 63: throw (DnsException "DNS name parts cannot exceed 63 bytes" --name=name)
    if part.size < 1: throw (DnsException "DNS name parts cannot be empty" --name=name)
    tail := name[pos..]
    pos += part.size + 1
    if locations:
      locations.get tail --if-present=: | location/int |
        if buffer: buffer.big-endian.write-int16 location + 0xc000
        length += 2
        return length
    if buffer:
      if locations: locations[tail] = buffer.size
      buffer.write-byte part.size
      buffer.write part
    length += part.size + 1
  if buffer: buffer.write-byte 0
  return length + 1
