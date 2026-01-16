// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import net
import net.modules.dns show *

main:
  network := net.open
  localhost-test network
  ipv6-address-test
  ipv6-dns-test network
  cache-test network
  fail-test network
  long-test network
  task:: fallback-test network
  task:: fallback-test-2 network

localhost-test network/net.Client:
  expect-equals "127.0.0.1" (dns-lookup "localhost" --network=network).stringify

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

ipv6-dns-test network/net.Client:
  ipv6 := dns-lookup "www.rwth-aachen.de"
      --network=network
      --accept-ipv6
      --no-accept-ipv4
  expect
      ipv6.stringify.starts-with "2a00:8a60:450:0:"

  ipv6 = dns-lookup "ipv6.google.com"
      --network=network
      --accept-ipv4
      --accept-ipv6
  print ipv6
  expect (ipv6.stringify.index-of ":") != -1

  ipv6 = dns-lookup "ipv6.google.com"
      --network=network
      --no-accept-ipv4
      --accept-ipv6
  print ipv6
  expect (ipv6.stringify.index-of ":") != -1

  ipv6 = dns-lookup "www.google.com"
      --network=network
      --no-accept-ipv4
      --accept-ipv6
  print ipv6
  expect (ipv6.stringify.index-of ":") != -1

  either := dns-lookup "www.google.com" --network=network --accept-ipv6
  print either

  // A domain that has no IPv6 address, but that's the only thing we will
  // accept.
  error := catch: dns-lookup "v4.ipv6test.app"
      --network=network
      --accept-ipv6
      --no-accept-ipv4
  print "IPv6: $error"
  expect
      error is DnsException

cache-test network/net.Client:
  // Prime cache.
  dns-lookup "www.apple.com" --network=network

  // We should easily be able to hit the cache in less than 5ms (a round trip
  // lookup takes minimum 15ms).
  duration := Duration.of: dns-lookup "www.apple.com" --network=network
  expect duration < (Duration --ms=5)

  // Prime cache.
  dns-lookup "www.yahoo.com" --network=network --no-accept-ipv4 --accept-ipv6

  // Make sure we use the IPV6 cache when both answers are OK.
  duration = Duration.of:
    address := dns-lookup "www.yahoo.com" --network=network --accept-ipv4 --accept-ipv6
    expect (address.stringify.index-of ":") != -1
  expect duration < (Duration --ms=5)

fail-test network/net.Client:
  error := catch: dns-lookup "does-not-resolve.example.com" --network=network
  print "      $error"
  expect error is DnsException
  exception := error as DnsException
  expect
    exception.text.contains "No name record found"

long-test network/net.Client:
  // As of 2022 these names both resolve, and the longer one has the max length
  // of a section, 63 characters.  If they start flaking we can remove this
  // again.
  print
      dns-lookup "llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch.co.uk"
          --network=network
  print
      dns-lookup "llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogochuchaf.com"
          --network=network

fallback-test network/net.Client:
  print "Doing fallback test - may pause for a few seconds"
  // There will be a short timeout (about 2.5 seconds), then it will switch to
  // Google and succeed.
  client := DnsClient [
      "240.0.0.0",  // Black hole that never answers.
      "8.8.8.8",    // Google DNS.
      ]
  dns-lookup --client=client "www.apple.com" --network=network
  print "Fell back to good server, should go fast again now."
  // Check that we switched permanently to the DNS server that answers quickly.
  with-timeout (DNS-RETRY-TIMEOUT * 2):
    dns-lookup --network=network --client=client "www.google.com"

  // The --server option still works.
  dns-lookup --network=network --server="8.8.4.4" "www.facebook.com"

  expect-throw "BAD_FORMAT":
    dns-lookup --network=network --server="5.5.5" "www.google.com"

fallback-test-2 network/net.Client:
  // Start with the server that returns an error, then fall back to the
  // one that times out. Verify that the good error is thrown.
  client := DnsClient [
      "8.8.8.8",    // Google DNS.
      "240.0.0.0",  // Black hole that never answers.
      ]

  error := catch: dns-lookup "no-such-host.example.com"
      --network=network
      --client=client
  expect
    (error as DnsException).text.contains "No name record found"
