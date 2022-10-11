// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .dns
import net

main:
  localhost_test
  ipv6_address_test
  ipv6_dns_test
  cache_test
  fail_test
  long_test
  parse_numeric_test

localhost_test:
  expect_equals "127.0.0.1" (dns_lookup "localhost").stringify

ipv6_address_test:
  addr := net.IpAddress [
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 1
  ]
  expect_equals "0:0:0:0:0:0:0:1" addr.stringify

  addr = net.IpAddress [
    1, 2, 3, 4, 5, 6, 7, 8,
    9, 10, 11, 12, 13, 14, 15, 16
  ]
  expect_equals "102:304:506:708:90a:b0c:d0e:f10" addr.stringify

ipv6_dns_test:
  ipv6 := dns_lookup "www.rwth-aachen.de" --accept_ipv6=true --accept_ipv4=false
  expect
      ipv6.stringify.starts_with "2a00:8a60:450:0:"

  ipv6 = dns_lookup "ipv6.google.com" --no-accept_ipv4 --accept_ipv6
  print ipv6
  expect (ipv6.stringify.index_of ":") != -1

  ipv6 = dns_lookup "ipv6.google.com" --accept_ipv4 --accept_ipv6
  print ipv6
  expect (ipv6.stringify.index_of ":") != -1

  ipv6 = dns_lookup "www.google.com" --no-accept_ipv4 --accept_ipv6
  print ipv6
  expect (ipv6.stringify.index_of ":") != -1

  either := dns_lookup "www.google.com" --accept_ipv6
  print either

cache_test:
  // Prime cache.
  dns_lookup "www.apple.com"

  // We should easily be able to hit the cache in less than 5ms (a round trip
  // lookup takes minimum 15ms).
  duration := Duration.of: dns_lookup "www.apple.com"
  expect duration < (Duration --ms=5)

  // Prime cache.
  dns_lookup "www.yahoo.com" --no-accept_ipv4 --accept_ipv6

  // Make sure we use the IPV6 cache when both answers are OK.
  duration = Duration.of:
    address := dns_lookup "www.yahoo.com" --accept_ipv4 --accept_ipv6
    expect (address.stringify.index_of ":") != -1
  expect duration < (Duration --ms=5)

fail_test:
  error := catch: dns_lookup "does-not-resolve.example.com"
  expect error is DnsException
  exception := error as DnsException
  expect
    exception.text.contains "NO_SUCH_DOMAIN"

long_test:
  // As of 2022 these names both resolve, and the longer one has the max length
  // of a section, 63 characters.  If they start flaking we can remove this
  // again.
  print
      dns_lookup "llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch.co.uk"
  print
      dns_lookup "llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogochuchaf.com"

parse_numeric_test:
  valid_ipv4 "0.0.0.0"
  valid_ipv4 "192.168.0.1"
  valid_ipv4 "255.255.255.255"
  invalid_ipv4 "01.02.092.1"         // Leading zeros are not allowed because some systems
                                     //   interpret this as octal, others as decimal.
  invalid_ipv4 "192.168.0.1.3"       // Too long.
  invalid_ipv4 "192.168.0."          // Too short.
  invalid_ipv4 "192.168.0"           // Too short.
  invalid_ipv4 "356.168.0.1"         // Too Hollywood.
  invalid_ipv4 ".168.0.1"            // Starts with dot.
  invalid_ipv4 "5000000000.168.0.1"  // Byte range.
  invalid_ipv4 "1_2.168.0.1"         // Toit number format not allowed.
  invalid_ipv4 "::"                  // That's an IPv6 address.

  invalid_ipv6 "192.168.0.1"         // That's an IPv4 address.
  valid_ipv6 "::"                    // All zeros
  invalid_ipv6 ":"
  valid_ipv6 "2001:db8:3333:4444:5555:6666:7777:8888"
  valid_ipv6 "2001:db8:3333:4444:CCCC:DDDD:EEEE:FFFF"
  valid_ipv6 "2001:db8::"            // Last 6 segments are zero.
  valid_ipv6 "::1234:5678"           // First 6 segments are zero.
  valid_ipv6 "2001:db8::1234:5678"   // Middle 4 segments are zero.
  valid_ipv6 "2001:0db8:0001:0000:0000:0ab9:C0A8:0102"  // Could be compressed
  invalid_ipv6 "::1234:5678::"       // Can't have compressed zeros at both ends.
  invalid_ipv6 "::1234:5678::0"      // Can't have compressed zeros in middle and start.
  invalid_ipv6 "1234:5678::0::"      // Can't have compressed zeros in middle and end.
  invalid_ipv6 "::123g:5678"         // Can't have 'g' in hex
  invalid_ipv6 "12345:5678::"        // Number too big.
  invalid_ipv6 "1235.5678::"         // No dots.
  invalid_ipv6 "::12345"             // Too long segment at end.

valid_ipv4 str/string -> none:
  expect
      net.IpAddress.is_valid str

invalid_ipv4 str/string -> none:
  expect_not
      net.IpAddress.is_valid str

valid_ipv6 str/string -> none:
  expect
      net.IpAddress.is_valid --no-accept_ipv4 --accept_ipv6 str

invalid_ipv6 str/string -> none:
  expect_not
      net.IpAddress.is_valid --no-accept_ipv4 --accept_ipv6 str
