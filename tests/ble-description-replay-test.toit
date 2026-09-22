// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system
import ble.experimental.attribute-server as attributes

// Unicode 17.0, section 3.9, Table 3-7 boundary encodings. Surrounding ASCII
// makes truncations and substitutions exercise code-point transitions too.
seeds -> List:
  return [
    #[0], #[0x7f], #[0xc2, 0x80], #[0xdf, 0xbf],
    #[0xe0, 0xa0, 0x80], #[0xed, 0x9f, 0xbf],
    #[0xee, 0x80, 0x80], #[0xef, 0xbf, 0xbf],
    #[0xf0, 0x90, 0x80, 0x80], #[0xf4, 0x8f, 0xbf, 0xbf],
  ]

main:
  with-timeout --ms=30_000:
    replay := Replay
    try:
      seeds.do: | scalar/ByteArray |
        seed := #[65] + scalar + #[90]
        replay.check seed
        seed.size.repeat: | offset/int |
          replay.check seed[..offset].copy
          256.repeat: | byte/int |
            value := seed.copy
            value[offset] = byte
            replay.check value
      replay.check #[]
      replay.malformed-execution
      expect-equals 3881 replay.accepted
      expect-equals 7952 replay.rejected
      print "description-replay accepted=$replay.accepted rejected=$replay.rejected"
    finally:
      replay.close

class Replay:
  database/attributes.Database := attributes.Database
  session/attributes.Session := ?
  vendor/int := ?
  description/int := ?
  accepted/int := 0
  rejected/int := 0

  constructor:
    database.add-service #[0xf0, 0xff]
    characteristic := database.add-characteristic #[0xf1, 0xff] --read
    vendor = database.add-descriptor characteristic #[0xf2, 0xff] --write --value=#[7]
    description = database.add-descriptor characteristic #[1, 0x29] --write --value=#[65]
    session = database.session

  close: session.close

  check bytes/ByteArray:
    valid := scalar-sequence bytes
    if valid: accepted++
    else: rejected++
    database.set-value vendor #[7]
    database.set-value description #[65]
    original := bytes.copy
    // Short writes reject malformed text without a value or callback change.
    response := session.request (#[0x12, description, 0] + bytes)
    expect-equals (valid ? #[0x13] : #[1, 0x12, description, 0, 0x13]) response
    check-values (valid ? bytes : #[65]) #[7]
    check-writes valid bytes --no-vendor

    database.set-value description #[65]
    // The non-text descriptor is staged first to expose partial commits.
    prepare vendor 0 #[99]
    if bytes.is-empty:
      prepare description 0 #[]
    else:
      // Every code point is split; only the final assembled value is text.
      bytes.size.repeat: | offset/int |
        prepare description offset bytes[offset..offset + 1]
    check-values #[65] #[7]
    session.writes-do: unreachable
    if (accepted + rejected) % 256 == 0: system.process-stats --gc
    response = session.request #[0x18, 1]
    expect-equals (valid ? #[0x19] : #[1, 0x18, description, 0, 0x13]) response
    check-values (valid ? bytes : #[65]) (valid ? #[99] : #[7])
    check-writes valid bytes --vendor
    expect-equals original bytes
    // Success and failure both discard every queued fragment and write record.
    expect-equals #[0x19] (session.request #[0x18, 1])
    session.writes-do: unreachable
    check-values (valid ? bytes : #[65]) (valid ? #[99] : #[7])

  prepare handle/int offset/int bytes/ByteArray:
    packet := #[0x16, handle, 0, offset, 0] + bytes
    expected := packet.copy
    expected[0] = 0x17
    expect-equals expected (session.request packet)
    // The queued fragment must own its bytes independently of both arrays.
    packet.fill 0
    expected.fill 0

  check-values text/ByteArray other/ByteArray:
    expect-equals text (database.value description)
    expect-equals other (database.value vendor)

  check-writes valid/bool text/ByteArray --vendor/bool:
    seen := {}
    session.writes-do: | handle/int bytes/ByteArray |
      expect valid
      expect (not (seen.contains handle))
      seen.add handle
      expect-equals (handle == description ? text : #[99]) bytes
      bytes.fill 0
    expect-equals (valid ? (vendor ? {description, this.vendor} : {description}) : {}) seen
    session.writes-do: unreachable
    check-values (valid ? text : #[65]) ((valid and vendor) ? #[99] : #[7])

  malformed-execution:
    malformed := [#[0x18], #[0x18, 1, 0], #[0x18] + (ByteArray 23)]
    254.repeat: malformed.add #[0x18, it + 2]
    malformed.do: | pdu/ByteArray |
      database.set-value vendor #[7]
      database.set-value description #[65]
      prepare vendor 0 #[99]
      prepare description 0 #[0xc3]
      expect-equals #[1, 0x18, 0, 0, 4] (session.request pdu)
      check-values #[65] #[7]
      session.writes-do: unreachable
      // Invalid Execute PDUs must not silently execute or cancel the queue.
      expect-equals #[1, 0x18, description, 0, 0x13] (session.request #[0x18, 1])
      check-values #[65] #[7]
      session.writes-do: unreachable
      prepare vendor 0 #[99]
      prepare description 0 #[0xc3]
      expect-equals #[0x19] (session.request #[0x18, 0])
      expect-equals #[0x19] (session.request #[0x18, 1])
      check-values #[65] #[7]
      session.writes-do: unreachable

// Independent scalar decoder: do not ask the SDK's UTF-8 validator for the
// expected verdict. Reject non-shortest forms, surrogates and values above
// U+10FFFF; unassigned code points and noncharacters are still well-formed.
scalar-sequence bytes/ByteArray -> bool:
  offset := 0
  while offset < bytes.size:
    first := bytes[offset]
    offset++
    if first < 0x80: continue
    width := first < 0xe0 ? 2 : (first < 0xf0 ? 3 : 4)
    if first < 0xc2 or first > 0xf4 or offset + width - 1 > bytes.size: return false
    scalar := first & ((1 << (7 - width)) - 1)
    (width - 1).repeat:
      next := bytes[offset]
      offset++
      if not 0x80 <= next <= 0xbf: return false
      scalar = scalar * 64 + next - 0x80
    minimum := width == 2 ? 0x80 : (width == 3 ? 0x800 : 0x10000)
    if scalar < minimum or scalar > 0x10ffff or 0xd800 <= scalar <= 0xdfff: return false
  return true
