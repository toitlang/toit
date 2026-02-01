// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import io
import net
import net.udp
import net.modules.dns

main:
  test-custom-mdns

test-custom-mdns:
  print "Custom mDNS test..."
  network := net.open
  server := network.udp-open --port=0
  port := server.local-address.port
  
  // Configure the default mDNS client to send to our local server.
  client := dns.MdnsDnsClient
      --address=(net.IpAddress.parse "127.0.0.1")
      --port=port
  dns.default-mdns-client = client
  
  // Test A record lookup
  task::
    // Server side.
    msg := server.receive
    // Parse the query ID (first 2 bytes).
    id := msg.data[0] << 8 | msg.data[1]
    
    // Construct response for A record.
    questions := [dns.Question "toit.local" dns.RECORD-A]
    answers := [dns.AResource "toit.local" 120 (net.IpAddress.parse "1.2.3.4")]
    response := dns.create-dns-packet questions answers --id=id --is-response --is-authoritative
    
    server.send (udp.Datagram response msg.address)

  res := client.get "toit.local" --record-type=dns.RECORD-A --network=network
  if res.size != 1 or res[0] != (net.IpAddress.parse "1.2.3.4"):
    throw "Expected 1.2.3.4, got $res"
  print "Custom mDNS A lookup: OK"

  // Test TXT record lookup.
  task::
    msg := server.receive
    id := msg.data[0] << 8 | msg.data[1]
    questions := [dns.Question "toit.local" dns.RECORD-TXT]
    answers := [dns.StringResource "toit.local" dns.RECORD-TXT 120 false "hello=world"]
    response := dns.create-dns-packet questions answers --id=id --is-response --is-authoritative
    server.send (udp.Datagram response msg.address)

  res-txt := client.get "toit.local" --record-type=dns.RECORD-TXT --network=network
  if res-txt.size != 1 or res-txt[0] != "hello=world":
    throw "Expected 'hello=world', got $res-txt"
  print "Custom mDNS TXT lookup: OK"

  // Test AAAA record lookup.
  task::
    msg := server.receive
    id := msg.data[0] << 8 | msg.data[1]
    questions := [dns.Question "toit.local" dns.RECORD-AAAA]
    ipv6-addr := net.IpAddress #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
    answers := [dns.AResource "toit.local" 120 ipv6-addr]
    response := dns.create-dns-packet questions answers --id=id --is-response --is-authoritative
    server.send (udp.Datagram response msg.address)

  res-aaaa := client.get "toit.local" --record-type=dns.RECORD-AAAA --network=network
  ipv6-local := net.IpAddress #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
  if res-aaaa.size != 1 or res-aaaa[0] != ipv6-local:
    throw "Expected ::1, got $res-aaaa"
  print "Custom mDNS AAAA lookup: OK"

  // Test SRV record lookup.
  task::
    msg := server.receive
    id := msg.data[0] << 8 | msg.data[1]
    // 10 0 5353 "target" (simple name).
    questions := [dns.Question "service.local" dns.RECORD-SRV]
    answers := [dns.SrvResource "service.local" dns.RECORD-SRV 120 false "target" 10 0 5353]
    response := dns.create-dns-packet questions answers --id=id --is-response --is-authoritative
    server.send (udp.Datagram response msg.address)

  res-srv := client.get "service.local" --record-type=dns.RECORD-SRV --network=network
  if res-srv.size != 1: throw "Expected 1 SRV record"
  srv/dns.SrvResource := res-srv[0]
  if srv.value != "target" or srv.priority != 10 or srv.port != 5353:
    throw "Expected SRV target 10 0 5353, got $srv.value $srv.priority $srv.weight $srv.port"
  print "Custom mDNS SRV lookup: OK"

  // Test PTR record lookup.
  task::
    msg := server.receive
    id := msg.data[0] << 8 | msg.data[1]
    questions := [dns.Question "ptr.local" dns.RECORD-PTR]
    answers := [dns.StringResource "ptr.local" dns.RECORD-PTR 120 false "instance.local"]
    response := dns.create-dns-packet questions answers --id=id --is-response --is-authoritative
    server.send (udp.Datagram response msg.address)
  
  res-ptr := client.get "ptr.local" --record-type=dns.RECORD-PTR --network=network
  if res-ptr.size != 1 or res-ptr[0] != "instance.local":
    throw "Expected 'instance.local', got $res-ptr"
  print "Custom mDNS PTR lookup: OK"

  // Test ID Mismatch (Relaxed check).
  // Server sends back ID+1.
  task::
    // Server side.
    msg := server.receive
    // Parse the query ID (first 2 bytes).
    id := msg.data[0] << 8 | msg.data[1]
    bad-id := (id + 1) & 0xFFFF
    
    // Construct response for A record.
    questions := [dns.Question "mismatch.local" dns.RECORD-A]
    answers := [dns.AResource "mismatch.local" 120 (net.IpAddress.parse "1.2.3.4")]
    // Send response with WRONG ID.
    response := dns.create-dns-packet questions answers --id=bad-id --is-response --is-authoritative
    
    server.send (udp.Datagram response msg.address)

  res-mismatch := client.get "mismatch.local" --record-type=dns.RECORD-A --network=network
  if res-mismatch.size != 1 or res-mismatch[0] != (net.IpAddress.parse "1.2.3.4"):
    throw "Expected 1.2.3.4, got $res-mismatch"
  print "Custom mDNS Mismatch ID lookup: OK"

  // Test Unsolicited (ID=0, No Questions).
  task::
    msg := server.receive
    
    // Construct response with NO questions and ID 0.
    questions := []
    answers := [dns.StringResource "unsolicited.local" dns.RECORD-TXT 120 false "foo=bar"]
    response := dns.create-dns-packet questions answers --id=0 --is-response --is-authoritative
    server.send (udp.Datagram response msg.address)

  res-unsolicited := client.get "unsolicited.local" --record-type=dns.RECORD-TXT --network=network
  if res-unsolicited.size != 1 or res-unsolicited[0] != "foo=bar":
    throw "Expected 'foo=bar', got $res-unsolicited"
  print "Custom mDNS Unsolicited lookup: OK"

  server.close
