// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import net
import net.modules.dns as dns

// Only the isolated rig's test names resolve. No forwarding or external DNS.
reply bytes/ByteArray address/net.IpAddress -> ByteArray?:
  query := dns.decode-packet bytes
  if query.is-response or query.questions.size != 1: return null
  question/dns.Question := query.questions.first
  known := question.name == "echo.rp2040.test" or question.name == "burst.rp2040.test"
  records := []
  if known and question.type == dns.RECORD-A:
    records.add (dns.AResource question.name 0 address)
  response := dns.create-dns-packet query.questions records
      --id=query.id
      --is-response
      --is-authoritative
  if not known: response[3] |= 3  // NXDOMAIN.
  return response
