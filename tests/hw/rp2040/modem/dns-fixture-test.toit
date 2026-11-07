// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import net
import net.modules.dns as dns
import .dns-fixture as fixture

main:
  address := net.IpAddress.parse "200.200.200.1"
  ["echo.rp2040.test", "burst.rp2040.test"].do: | name |
    query := dns.create-dns-packet [dns.Question name dns.RECORD-A] []
        --id=0x7654
        --no-is-response
    response := fixture.reply query address
    decoded := dns.decode-packet response
    expect decoded.is-response
    expect decoded.is-authoritative
    expect-equals 0x7654 decoded.id
    expect-equals name decoded.questions.first.name
    expect-equals 1 decoded.resources.size
    expect-equals address decoded.resources.first.address
    expect-equals 0 decoded.resources.first.ttl
    expect-equals null (fixture.reply response address)
  query := dns.create-dns-packet [dns.Question "absent.rp2040.test" dns.RECORD-A] []
      --id=1
      --no-is-response
  response := fixture.reply query address
  expect-equals 3 (response[3] & 15)
  // Clear the response code to inspect the negative packet's question section.
  response[3] &= 0xf0
  decoded := dns.decode-packet response
  expect-equals "absent.rp2040.test" decoded.questions.first.name
  expect decoded.resources.is-empty
  print "RP2040 helper DNS fixture: PASS"
