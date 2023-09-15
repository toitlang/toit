// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .dns
import net

main:
  localhost-test
  ipv6-address-test
  ipv6-dns-test
  cache-test
  fail-test
  long-test
  txt-test
  cname-test
  parse-numeric-test
  task:: fallback-test
  task:: fallback-test-2

localhost-test:
  expect-equals "127.0.0.1" (dns-lookup "localhost").stringify

ipv6-address-test:
  addr := net.IpAddress [
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 1
  ]
  expect-equals "0:0:0:0:0:0:0:1" addr.stringify

  addr = net.IpAddress [
    1, 2, 3, 4, 5, 6, 7, 8,
    9, 10, 11, 12, 13, 14, 15, 16
  ]
  expect-equals "102:304:506:708:90a:b0c:d0e:f10" addr.stringify

ipv6-dns-test:
  ipv6 := dns-lookup "www.rwth-aachen.de" --accept-ipv6=true --accept-ipv4=false
  expect
      ipv6.stringify.starts-with "2a00:8a60:450:0:"

  ipv6 = dns-lookup "ipv6.google.com" --accept-ipv4 --accept-ipv6
  print ipv6
  expect (ipv6.stringify.index-of ":") != -1

  ipv6 = dns-lookup "ipv6.google.com" --no-accept-ipv4 --accept-ipv6
  print ipv6
  expect (ipv6.stringify.index-of ":") != -1

  ipv6 = dns-lookup "www.google.com" --no-accept-ipv4 --accept-ipv6
  print ipv6
  expect (ipv6.stringify.index-of ":") != -1

  either := dns-lookup "www.google.com" --accept-ipv6
  print either

  // A domain that has no IPv6 address, but that's the only thing we will
  // accept.
  error := catch: dns-lookup "toitlang.org" --accept-ipv6 --no-accept-ipv4
  print "IPv6: $error"
  expect
      error is DnsException

cache-test:
  // Prime cache.
  dns-lookup "www.apple.com"

  // We should easily be able to hit the cache in less than 5ms (a round trip
  // lookup takes minimum 15ms).
  duration := Duration.of: dns-lookup "www.apple.com"
  expect duration < (Duration --ms=5)

  // Prime cache.
  dns-lookup "www.yahoo.com" --no-accept-ipv4 --accept-ipv6

  // Make sure we use the IPV6 cache when both answers are OK.
  duration = Duration.of:
    address := dns-lookup "www.yahoo.com" --accept-ipv4 --accept-ipv6
    expect (address.stringify.index-of ":") != -1
  expect duration < (Duration --ms=5)

fail-test:
  error := catch: dns-lookup "does-not-resolve.example.com"
  print "      $error"
  error as DnsException
  expect error is DnsException
  exception := error as DnsException
  expect
    exception.text.contains "NO_SUCH_DOMAIN"

long-test:
  // As of 2022 these names both resolve, and the longer one has the max length
  // of a section, 63 characters.  If they start flaking we can remove this
  // again.
  print
      dns-lookup "llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch.co.uk"
  print
      dns-lookup "llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogochuchaf.com"

txt-test:
  client := DnsClient [
      "8.8.8.8",    // Google DNS.
      ]
  texts := client.get --record-type=RECORD-TXT "toit.io"
  expect
      texts.contains "OSSRH-61647"
  ptr := client.get --record-type=RECORD-PTR "toit.io"
  expect
      ptr.size == 0
  srv := client.get --record-type=RECORD-SRV "toit.io"
  expect
      srv.size == 0

cname-test:
  client := DnsClient [
      "8.8.8.8",    // Google DNS.
      ]
  // Normally CNAME results are just consumed internally in our DNS code, but
  // we can explicitly ask for them.
  cname := client.get --record-type=RECORD-CNAME "www.yahoo.com"
  expect
      cname.size > 0
  cname.do: | name |
    expect
        name != "www.yahoo.com"
    expect
        name.ends-with ".yahoo.com"

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

fallback-test:
  print "Doing fallback test - may pause for a few seconds"
  // There will be a short timeout (about 2.5 seconds), then it will switch to
  // Google and succeed.
  client := DnsClient [
      "240.0.0.0",  // Black hole that never answers.
      "8.8.8.8",    // Google DNS.
      ]
  dns-lookup --client=client "www.apple.com"
  print "Fell back to good server, should go fast again now."
  // Check that we switched permanently to the DNS server that answers quickly.
  with-timeout (DNS-RETRY-TIMEOUT * 2): dns-lookup --client=client "www.google.com"

  // The --server option still works.
  dns-lookup --server="8.8.4.4" "www.facebook.com"

  expect-throw "BAD_FORMAT": dns-lookup --server="5.5.5" "www.google.com"

fallback-test-2:
  // Start with the server that returns an error, then fall back to the
  // one that times out. Verify that the good error is thrown.
  client := DnsClient [
      "8.8.8.8",    // Google DNS.
      "240.0.0.0",  // Black hole that never answers.
      ]

  error := catch: dns-lookup --client=client "no-such-host.example.com"
  expect
    (error as DnsException).text.contains "NO_SUCH_DOMAIN"

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
