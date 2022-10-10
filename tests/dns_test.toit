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
  dns_query := DnsQuery_ "www.rwth-aachen.de"
  ipv6 := dns_query.get --server="8.8.8.8" --accept_ipv6=true
  expect ipv6.stringify == "2a00:8a60:450:0:0:0:107:63"

cache_test:
  // Prime cache.
  dns_lookup "www.apple.com"

  // We should easily be able to hit the cache in less than 5ms (a round trip
  // lookup takes about 15ms).
  duration := Duration.of: dns_lookup "www.apple.com"
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
