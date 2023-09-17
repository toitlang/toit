// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary show BIG-ENDIAN
import bytes show Buffer
import net.modules.udp as udp-module
import net
import .dns-tools as dns-tools

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
  query-packets/Map  // From record type (int) to packet (ByteArray)

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
  If the $record-type is $RECORD-SRV, the results are instances of $dns-tools.SrvResource
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

      result := dns-tools.find-in-cache cache_ name record-type
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
    decoded := dns-tools.decode-packet response --error-name=query.name

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
    decoded-question/dns-tools.Question := decoded.questions[0] as dns-tools.Question

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
        if resource is dns-tools.StringResource:
          answers.add (resource as dns-tools.StringResource).value
        else if resource is dns-tools.AResource:
          answers.add (resource as dns-tools.AResource).address
        else:
          answers.add (resource as dns-tools.SrvResource)
        ttl = min ttl resource.ttl
      else if resource.type == RECORD-CNAME:
        relevant-name = (resource as dns-tools.StringResource).value

    // We won't cache more than a day, even if the TTL is very high.  (In
    // practice TTLs over one hour are rare.)
    ttl = min ttl (3600 * 24)
    // Ignore negative TTLs.
    ttl = max 0 ttl

    if answers.size > 0 and ttl > 0:
      dns-tools.trim-cache cache_ expected-type
      type-cache := cache_.get expected-type --init=: {:}
      type-cache[query.name] = dns-tools.CacheEntry_ answers ttl
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
  dns-tools.write-name_ name --locations=null --buffer=result
  result.write-int16-big-endian record-type
  result.write-int16-big-endian CLASS-INTERNET
  return result.bytes

select-random-ip_ name/string list/List -> net.IpAddress:
  if list and list.size > 0:
    return list[random list.size]  // Randomize which of the IP's we return.
  throw (DnsException "No name record found" --name=name)

is-server-reachability-error_ error -> bool:
  return error == DEADLINE-EXCEEDED-ERROR or error is string and error.starts-with "A socket operation was attempted to an unreachable network"
