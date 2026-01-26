// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import net
import net.modules.dns
import expect show *

main:
  test-srv-encoding
  test-txt-encoding
  test-ptr-encoding-length
  test-aaaa-encoding

test-srv-encoding:
  print "Testing SRV encoding..."
  questions := [dns.Question "service.local" dns.RECORD-SRV]
  // We use "target.local" to verify that compression works within the SRV record.
  // "local" should match the "local" suffix of "service.local" in the question.
  answers := [dns.SrvResource "service.local" dns.RECORD-SRV 120 false "target.local" 10 5 5353]
  
  packet := dns.create-dns-packet questions answers --id=0x1234 --is-response --is-authoritative

  // Verify structure
  // Header: 12 bytes
  // Question: "service.local"
  //   - \x07 "service" \x05 "local" \x00
  //   - Offsets: "service.local"@12, "local"@20.
  //   - Total 17 bytes (12..29)
  
  // Answer: "service.local" (ptr to 12 -> C0 0C)
  // ...
  // SRV RDATA:
  // Target: "target.local"
  //   - \x06 "target"
  //   - "local" matches offset 20 -> \xC0 \x14
  //   - Size: 7 + 2 = 9 bytes.

  // Check ID
  expect-equals 0x12 packet[0]
  expect-equals 0x34 packet[1]
  
  // rdata start at: 12(header) + 17(Q) + 2(name) + 2(type) + 2(class) + 4(TTL) + 2(rdlen) = 41. (Index of RDLENGTH is 41)
  
  rdlength-idx := 41
  rdlength := packet[rdlength-idx] << 8 | packet[rdlength-idx + 1]
  
  // RDLENGTH = 2(prio)+2(weight)+2(port)+9(target) = 15.
  expect-equals 15 rdlength
  
  rdata-idx := 43
  
  // Target start at rdata-idx + 6 = 49.
  // "target" (len 6)
  expect-equals 6 packet[49]
  expect-equals 't' packet[50] // 't'
  
  // Compression pointer for ".local".
  // "target" is 1+6 = 7 bytes long (idx 49..55).
  // Next 2 bytes should be C0 14 (20).
  expect-equals 0xC0 packet[56]
  expect-equals 0x14 packet[57]

  print "SRV encoding: OK"

test-txt-encoding:
  print "Testing TXT encoding..."
  questions := [dns.Question "txt.local" dns.RECORD-TXT]
  txt-value := "hello"
  answers := [dns.StringResource "txt.local" dns.RECORD-TXT 120 false txt-value]
  
  packet := dns.create-dns-packet questions answers --id=0 --is-response --is-authoritative
  
  // Find answer section.
  // Header(12) + Question(3txt 5local 0) + 4) = 12 + 11 + 4 = 27.
  // Answer starts at 27.
  // Pointer(2) + Type(2) + Class(2) + TTL(4) + RDLENGTH(2) = 12 bytes.
  // RDATA starts at 27 + 12 = 39.
  
  rdata-idx := 39
  
  // TXT RDATA record structure:
  // [Length Byte] [String Bytes]
  // So for "hello" (5 bytes), we expect:
  // 05 'h' 'e' 'l' 'l' 'o'
  // And RDLENGTH should be 6.
  
  rdlength := packet[rdata-idx - 2] << 8 | packet[rdata-idx - 1]
  expect-equals (txt-value.size + 1) rdlength
  
  txt-len := packet[rdata-idx]
  expect-equals txt-value.size txt-len
  expect-equals 'h' packet[rdata-idx + 1]
  
  print "TXT encoding: OK"

test-ptr-encoding-length:
  print "Testing PTR encoding and compression length..."
  // This specifically targets the off-by-one error in length calculation for compressed names.
  name := "ptr.local"
  target := "instance.local"
  
  questions := [dns.Question name dns.RECORD-PTR]
  answers := [dns.StringResource name dns.RECORD-PTR 120 false target]
  
  packet := dns.create-dns-packet questions answers --id=0 --is-response --is-authoritative
  
  // Header (12)
  // Question: 3 ptr 5 local 0 (1+3+1+5+1 = 11) + 4 = 15 bytes.
  // Answer: Pointer to name (2) + Type(2) + Class(2) + TTL(4) + RDLENGTH(2)
  // RDATA: "instance.local"
  // "local" is already in the packet (at offset 12+1+3 = 16).
  // "instance" is 1+8 bytes.
  // So "instance.local" should be encoded as:
  // 8 instance [Pointer to "local"]
  // Length: 1 + 8 + 2 = 11 bytes.
  
  // If the bug (initial length=1) was present, calculated length might be different than written.
  
  // Find RDLENGTH.
  // Header: 12
  // Question: 11 + 4 = 15.
  // Answer header: 12.
  // Offset to RDLENGTH: 12 + 15 + 10 = 37.
  
  rdl-idx := 37
  rdlength := packet[rdl-idx] << 8 | packet[rdl-idx + 1]
  
  // Expected:
  // "instance" (8) + len(1) = 9
  // Pointer (2)
  // Total 11.
  expect-equals 11 rdlength
  
  // Verify trailing bytes don't contain extra 0 if compressed.
  // RDATA starts at 39.
  // 08 'i' ... 'e' C0 10 (pointer to 16 [local])
  rdata-idx := 39
  expect-equals 8 packet[rdata-idx] // "instance" length
  expect-equals 0xC0 packet[rdata-idx + 9] // Pointer marker
  
  print "PTR encoding: OK"

test-aaaa-encoding:
  print "Testing AAAA encoding..."
  questions := [dns.Question "ipv6.local" dns.RECORD-AAAA]
  addr := net.IpAddress #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
  answers := [dns.AResource "ipv6.local" dns.RECORD-AAAA 120 false addr]
  
  packet := dns.create-dns-packet questions answers --id=0 --is-response --is-authoritative
  
  // Verify RDLENGTH is 16
  // Header 12
  // Question: 4 ipv6 5 local 0 (1+4+1+5+1 = 12) + 4 = 16.
  // Answer Header: 12.
  // RDLENGTH offset: 12 + 16 + 10 = 38.
  
  rdl-idx := 38
  rdlength := packet[rdl-idx] << 8 | packet[rdl-idx + 1]
  expect-equals 16 rdlength
  
  print "AAAA encoding: OK"
