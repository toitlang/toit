// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import net
import net.udp
import net.modules.dns
import expect show *


main:
  test-mdns-mixed-caching
  test-standard-dns-retry

test-mdns-mixed-caching:
  print "Test: mDNS Mixed Type Caching (Unsolicited)"
  network := net.open
  server := network.udp-open --port=0
  port := server.local-address.port
  
  client := dns.MdnsDnsClient
      --address=(net.IpAddress.parse "127.0.0.1")
      --port=port
  dns.default-mdns-client = client

  // We want to test that if we ask for A and TXT, and get a single unsolicited packet
  // with BOTH, both are cached.
  //
  // Strategy:
  // 1. Issue a query for Type A and AAAA (IPv6).
  // 2. Server responds with A AND AAAA records in an unsolicited packet (ID=0).
  // 3. Client receives both.
  // 4. Client should have cached both types.
  // 5. Verify caching by verifying looking up one type doesn't trigger a network request
  //    (we stop the server to prove this).
  
  task::
    msg := server.receive
    // Respond with ID 0 (Unsolicited).
    questions := []
    answers := [
      dns.AResource "mixed.local" 120 (net.IpAddress.parse "1.2.3.4"),
      dns.StringResource "mixed.local" dns.RECORD-TXT 120 false "foo=bar"
    ]
    response := dns.create-dns-packet questions answers --id=0 --is-response --is-authoritative
    server.send (udp.Datagram response msg.address)

  print "  Step 1: Querying for A and AAAA (IPv6)"
  // dns.dns-lookup-multi calls client.get_ with {A, AAAA} if configured.
  
  task::
    // Server logic again for the A/AAAA test.
    msg := server.receive
    // ID 0.
    questions := []
    answers := [
      dns.AResource "mixed.local" 120 (net.IpAddress.parse "1.2.3.4"),
      dns.AResource "mixed.local" 120 (net.IpAddress #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    ]
    response := dns.create-dns-packet questions answers --id=0 --is-response --is-authoritative
    server.send (udp.Datagram response msg.address)

  results := dns.dns-lookup-multi "mixed.local"
      --client=client
      --accept-ipv4
      --accept-ipv6
      --network=network

  expect (results.contains (net.IpAddress.parse "1.2.3.4"))
  expect (results.contains (net.IpAddress #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]))
  
  print "  Step 2: verifying cache"
  // Now close server.
  server.close
  
  // Ask again. Should be cached.
  // The client instance `client` has the cache. We reuse it.
  
  // Verify A record is cached
  print "  Step 2a: verify A record cache"
  results_a := dns.dns-lookup-multi "mixed.local"
      --client=client
      --accept-ipv4
      --no-accept-ipv6
      --network=network
  
  expect (results_a.contains (net.IpAddress.parse "1.2.3.4"))

  // Verify AAAA record is cached
  print "  Step 2b: verify AAAA record cache"
  results_aaaa := dns.dns-lookup-multi "mixed.local"
      --client=client
      --no-accept-ipv4
      --accept-ipv6
      --network=network

  expect (results_aaaa.contains (net.IpAddress #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]))
  
  print "mDNS Mixed Caching: OK"

test-standard-dns-retry:
  print "Test: Standard DNS Retry/Fallback (Bug Fix)"
  network := net.open
  
  // Setup 2 servers.
  // 1. Silent (Mock UDP that reads but never replies).
  // 2. Responsive (Mock UDP that replies).
  
  s1 := network.udp-open --port=0
  s2 := network.udp-open --port=0
  
  ip_s1 := net.IpAddress.parse "127.0.0.1"
  port_s1 := s1.local-address.port
  
  ip_s2 := net.IpAddress.parse "127.0.0.1"
  port_s2 := s2.local-address.port
  
  // Silent server logic.
  task::
    e := catch:
      while true:
        msg := s1.receive
        // Do nothing, let client timeout.
    expect-not-null e
    expect (e == "CLOSED" or e == "NOT_CONNECTED")

  // Responsive server logic.
  task::
    e := catch:
      while true:
        msg := s2.receive
        id := msg.data[0] << 8 | msg.data[1]
        questions := [dns.Question "retry.local" dns.RECORD-A]
        answers := [dns.AResource "retry.local" 120 (net.IpAddress.parse "5.6.7.8")]
        response := dns.create-dns-packet questions answers --id=id --is-response --is-authoritative
        s2.send (udp.Datagram response msg.address)
    expect-not-null e
    expect (e == "CLOSED" or e == "NOT_CONNECTED")

  // Configure Client with [Silent, Responsive].
  // Uses new SocketAddress support from our refactor.
  client := dns.DnsClient [
    net.SocketAddress ip_s1 port_s1,
    net.SocketAddress ip_s2 port_s2
  ]

  print "  Querying... (should timeout on first server then succeed on second)"
  // This should take about DNS-RETRY-TIMEOUT (600ms) to fail first, then succeed.
  
  results := client.get "retry.local" --record-type=dns.RECORD-A --network=network
  
  expect-equals 1 results.size
  expect-equals (net.IpAddress.parse "5.6.7.8") results[0]
  
  print "Standard DNS Retry: OK"
  
  s1.close
  s2.close
