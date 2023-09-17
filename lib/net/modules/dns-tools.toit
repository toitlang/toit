// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary show BIG_ENDIAN
import bytes show Buffer
import .dns
import net

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
    q-name := decode-name_ response position: position = it
    q-type := BIG-ENDIAN.uint16 response position
    q-class := BIG-ENDIAN.uint16 response position + 2
    position += 4
    unicast-ok := q-class & 0x8000 != 0
    if q-class & 0x7fff != CLASS-INTERNET: protocol-error_  // Unexpected response class.

    result.questions.add
        Question q-name q-type --unicast-ok=unicast-ok

  response-count.repeat:
    r-name := decode-name_ response position: position = it
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
              decode-name_ response position: null
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
decode-name_ packet/ByteArray position/int [position-block] -> string:
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

