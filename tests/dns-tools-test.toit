// Copyright (C) 2013 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import net
import net.modules.dns

main:
  network := net.open
  txt-test network
  cname-test network
  parse-numeric-test
  encode-decode-packets-test

txt-test network/net.Client:
  client := dns.DnsClient [
      "8.8.8.8",    // Google DNS.
      ]
  texts := client.get --record-type=dns.RECORD-TXT --network=network "toit.io"
  expect
      texts.size == 2
  ptr := client.get --record-type=dns.RECORD-PTR --network=network "toit.io"
  expect
      ptr.size == 0
  srv := client.get --record-type=dns.RECORD-SRV --network=network "toit.io"
  expect
      srv.size == 0

cname-test network/net.Client:
  client := dns.DnsClient [
      "8.8.8.8",    // Google DNS.
      ]
  // Normally CNAME results are just consumed internally in our DNS code, but
  // we can explicitly ask for them.
  cname := client.get --record-type=dns.RECORD-CNAME --network=network "www.yahoo.com"
  expect
      cname.size > 0
  cname.do: | name |
    expect
        name != "www.yahoo.com"
    expect
        (name.ends-with ".yahoo.com") or (name.ends-with ".yahoodns.net")

parse-numeric-test:
  valid-ipv4 "0.0.0.0"
  valid-ipv4 "192.168.0.1"
  valid-ipv4 "255.255.255.255"
  invalid-ipv4 "01.02.092.1"         // Leading zeros are not allowed because some systems
                                     //   interpret this as octal, others as decimal.
  invalid-ipv4 "192.168.0.1.3"       // Too long.
  invalid-ipv4 "192.168.0."          // Too short.
  invalid-ipv4 "192.168.0"           // Too short.
  invalid-ipv4 "256.168.0.1"         // Off by one.
  invalid-ipv4 "312.168.0.1"         // Too Hollywood.
  invalid-ipv4 ".168.0.1"            // Starts with dot.
  invalid-ipv4 "5000000000.168.0.1"  // Byte range.
  invalid-ipv4 "1_2.168.0.1"         // Toit number format not allowed.
  invalid-ipv4 "::"                  // That's an IPv6 address.

  invalid-ipv6 "192.168.0.1"         // That's an IPv4 address.
  valid-ipv6 "::"                    // All zeros
  invalid-ipv6 ":"
  valid-ipv6 "2001:db8:3333:4444:5555:6666:7777:8888"
  valid-ipv6 "2001:db8:3333:4444:CCCC:DDDD:EEEE:FFFF"
  valid-ipv6 "2001:db8::"            // Last 6 segments are zero.
  valid-ipv6 "::1234:5678"           // First 6 segments are zero.
  valid-ipv6 "2001:db8::1234:5678"   // Middle 4 segments are zero.
  valid-ipv6 "2001:0db8:0001:0000:0000:0ab9:C0A8:0102"  // Could be compressed
  invalid-ipv6 "::1234:5678::"       // Can't have compressed zeros at both ends.
  invalid-ipv6 "::1234:5678::0"      // Can't have compressed zeros in middle and start.
  invalid-ipv6 "1234:5678::0::"      // Can't have compressed zeros in middle and end.
  invalid-ipv6 "::123g:5678"         // Can't have 'g' in hex
  invalid-ipv6 "12345:5678::"        // Number too big.
  invalid-ipv6 "1235.5678::"         // No dots.
  invalid-ipv6 "::12345"             // Too long segment at end.

valid-ipv4 str/string -> none:
  expect
      net.IpAddress.is-valid str

invalid-ipv4 str/string -> none:
  expect-not
      net.IpAddress.is-valid str

valid-ipv6 str/string -> none:
  expect
      net.IpAddress.is-valid --no-accept-ipv4 --accept-ipv6 str

invalid-ipv6 str/string -> none:
  expect-not
      net.IpAddress.is-valid --no-accept-ipv4 --accept-ipv6 str

encode-decode-packets-test:
  queries := [
      dns.Question "toitlang.org" dns.RECORD-A
  ]

  packet := dns.create-dns-packet queries [] --id=123 --is-response=false
  decoded := dns.decode-packet packet

  expect-equals 123 decoded.id
  expect-equals 1 decoded.questions.size
  expect-equals 0 decoded.resources.size
  expect-equals "toitlang.org" decoded.questions[0].name

  resources := [
      dns.AResource "toitlang.org" 120 (net.IpAddress.parse "10.11.12.13")
  ]
  packet-2 := dns.create-dns-packet queries resources --id=42 --is-response=true
  decoded-2 := dns.decode-packet packet-2

  expect-equals 42 decoded-2.id
  expect-equals 1 decoded-2.questions.size
  expect-equals 1 decoded-2.resources.size
  expect decoded-2.questions[0] is dns.Question
  expect decoded-2.resources[0] is dns.AResource
  expect-equals "toitlang.org" decoded-2.questions[0].name
  expect-equals "toitlang.org" decoded-2.resources[0].name
  expect-equals "10.11.12.13"
      (decoded-2.resources[0] as dns.AResource).address.stringify

  // Check we compressed so there is only one '1' in the binary encoding.
  first-l := packet.index-of 'l'
  expect first-l > 0
  second-l := packet[first-l + 1..].index-of 'l'
  expect second-l < 0  // Not found.

