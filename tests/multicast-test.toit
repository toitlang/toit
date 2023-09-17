// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import binary show BIG-ENDIAN
import bytes show Buffer
import expect show *

import .udp as udp
import net
import net.udp as net
import .dns as dns

main:
  encode-decode-packets-test
  multicast-test

multicast-test:
  times := 10

  port := 5353  // MDNS.

  socket := udp.Socket "224.0.0.251" port

  socket.multicast-add-membership
      net.IpAddress.parse "224.0.0.0"
  socket.multicast-loopback = true

  print "Listening"
  while true:
    datagram/net.Datagram := socket.receive
    if datagram.address.port == 5353:
      decoded := dns.decode-packet datagram.data
      print "Received $(decoded.is-response ? "response" : "query") packet from $datagram.address.ip"
      decoded.questions.do: | question |
        type := dns.QTYPE-NAMES.get question.type --if-absent=: "Unknown $question.type"
        print "  Q $question.name $type"
      decoded.resources.do: | resource |
        type := dns.QTYPE-NAMES.get resource.type --if-absent=: "Unknown $resource.type"
        print "  R $resource.name $resource.ttl $type $resource.value-string"

bytes-needed_ name/string locations/Map -> int:
  parts := name.split "."
  length := 1
  pos := 0
  parts.do: | part/string |
    tail := name[pos..]
    pos += part.size + 1
    locations.get tail --if-present=:
      length += 2
      return length
    length += part.size + 1
  return length

write-name_ name/string locations/Map buffer/Buffer -> none:
  parts := name.split "."
  pos := 0
  parts.do: | part/string |
    if part.size > 63: throw (dns.DnsException "DNS name parts cannot exceed 63 bytes" --name=name)
    if part.size < 1: throw (dns.DnsException "DNS name parts cannot be empty" --name=name)
    tail := name[pos..]
    pos += part.size + 1
    locations.get tail --if-present=: | location/int |
      buffer.write-int16-big-endian location + 0xc000
      return
    locations[tail] = buffer.size
    buffer.write-byte part.size
    buffer.write part
  buffer.write-byte 0

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

  queries.do: | query/dns.Question |
    write-name_ query.name previous-locations result
    result.write-int16-big-endian query.type
    clas := dns.CLASS-INTERNET + (query.unicast-ok ? 0x8000 : 0)
    result.write-int16-big-endian clas
  records.do: | record/dns.Resource |
    write-name_ record.name previous-locations result
    type := record.type
    result.write-int16-big-endian type
    clas := dns.CLASS-INTERNET + (record.flush ? 0x8000 : 0)
    result.write-int16-big-endian clas
    result.write-int32-big-endian record.ttl
    if record is dns.AResource:
      bytes := (record as dns.AResource).address.raw
      result.write-int16-big-endian bytes.size
      result.write bytes
    else if type == dns.RECORD-CNAME or type == dns.RECORD-PTR:
      str := (record as dns.StringResource).value
      length := bytes-needed_ str previous-locations
      result.write-int16-big-endian length
      write-name_ str previous-locations result
    else if type == dns.RECORD-TXT:
      str := (record as dns.StringResource).value
      if str.size > 255: throw (dns.DnsException "TXT records cannot exceed 255 bytes" --name=str)
      result.write-int16-big-endian str.size
      result.write str
    else if record is dns.SrvResource:
      srv := record as dns.SrvResource
      str := srv.value
      if str.size > 255: throw (dns.DnsException "SRV records cannot exceed 255 bytes" --name=str)
      result.write-int16-big-endian (str.size + 7)
      result.write-int16-big-endian srv.priority
      result.write-int16-big-endian srv.weight
      result.write-int16-big-endian srv.port
      result.write-byte str.size
      result.write str
    else:
      throw "Unknown record type: $record"
  return result.bytes
