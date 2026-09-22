// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.signaling
import expect show *
import io

main:
  exact-responses
  unknown-commands
  // Exercise every command octet around the signaling MTU, including short
  // headers, exact lengths and inconsistent declared lengths.
  256.repeat: | code/int |
    33.repeat: | size/int |
      packet := ByteArray size --initial=0
      if size > 0: packet[0] = code
      if size > 1: packet[1] = 7
      if size >= 4: io.LITTLE-ENDIAN.put-uint16 packet 2 (size - 4)
      check packet
      if size >= 4:
        packet[2]++
        check packet

  // Equality at the supervision relationship is invalid; one timeout unit
  // above it is valid. Include both ends of the interval and latency ranges.
  [6, 12, 40, 3200].do: | interval/int |
    [0, 1, 10, 499].do: | latency/int |
      threshold := ((latency + 1) * interval) / 4
      [threshold, threshold + 1].do: | timeout/int |
        valid := 10 <= timeout <= 3200 and
            timeout * 4 > (latency + 1) * interval
        failure := catch:
          packet := signaling.parameter-request 7 --interval=interval
              --latency=latency
              --supervision-timeout=timeout
          expect valid
          parsed := signaling.decode-parameter-request packet
          expect parsed.valid
          expect-equals interval parsed.interval-min
          expect-equals interval parsed.interval-max
          expect-equals latency parsed.latency
          expect-equals timeout parsed.supervision-timeout
        if failure:
          expect-equals "INVALID_ARGUMENT" failure
          expect (not valid)

  // Saved deterministic seed. Alternate arbitrary framing with correct outer
  // lengths so malformed payloads reach the individual command decoders.
  state := 130_013
  10_000.repeat: | index/int |
    state = (1664525 * state + 1013904223) & 0xffff_ffff
    packet := ByteArray (state % 65):
      state = (1664525 * state + 1013904223) & 0xffff_ffff
      state >> 16 & 0xff
    if packet.size >= 4 and index % 2 == 0:
      io.LITTLE-ENDIAN.put-uint16 packet 2 (packet.size - 4)
      packet[1] = 7
    if packet.size >= 1 and index % 3 == 0: packet[0] = 0x12
    check packet

unknown-commands:
  // L2CAP.TS.p42, LE/REJ/BI-02-C, Table 4.26, pages 237-238.
  // This host has no dynamic channels. Parameter updates are supported and
  // tested separately. Exercise every RFU code instead of a random subset.
  requests := [0x02, 0x04, 0x06, 0x08, 0x0a, 0x0c, 0x0e, 0x10,
    0x14, 0x16, 0x17, 0x19]
  (256 - 0x1b).repeat: requests.add (it + 0x1b)
  [false, true].do: | peripheral/bool |
    requests.do: | code/int |
      [1, 7, 255].do: | identifier/int |
        request := #[code, identifier, 0, 0]
        original := request.copy
        reject := #[1, identifier, 2, 0, 0, 0]
        expect-equals reject (signaling.response request --peripheral=peripheral)
        expect-equals original request
        expect-null (signaling.response reject --peripheral=peripheral)
    // The procedure explicitly permits either silence or a correctly encoded
    // rejection for unsupported responses. Do not require one implementation.
    [0x03, 0x05, 0x07, 0x09, 0x0b, 0x0d, 0x0f, 0x11,
        0x15, 0x18, 0x1a].do: | code/int |
      reply := signaling.response #[code, 7, 0, 0] --peripheral=peripheral
      if reply: expect-equals #[1, 7, 2, 0, 0, 0] reply

exact-responses:
  // Core 6.3, Vol 3 Part A, 4.1: Command Reject reason 0 has no data;
  // reason 1 includes the receiver's signaling MTU (23 for this host).
  expect-equals #[1, 7, 2, 0, 0, 0] (signaling.response #[0xff, 7, 0, 0])
  over-mtu := #[0xff, 7, 20, 0] + (ByteArray 20)
  expect-equals #[1, 7, 4, 0, 1, 0, 23, 0] (signaling.response over-mtu)
  // An invalid identifier must not elicit a response, even above MTUsig.
  over-mtu[1] = 0
  expect-null (signaling.response over-mtu)
  // Core 6.3, 4.20-4.21: only the peripheral initiates this procedure.
  // The generic central policy rejects parameters; the peripheral rejects
  // the command itself. Neither rejection can start a response loop.
  request := #[0x12, 9, 8, 0, 12, 0, 12, 0, 0, 0, 0x90, 1]
  rejected := #[0x13, 9, 2, 0, 1, 0]
  expect-equals rejected (signaling.response request)
  expect-equals #[1, 9, 2, 0, 0, 0] (signaling.response request --peripheral)
  expect-null (signaling.response rejected)
  expect-equals 0 (signaling.parameter-response #[0x13, 9, 2, 0, 0, 0] 9)
  expect-equals 1 (signaling.parameter-response rejected 9)
  expect-null (signaling.parameter-response rejected 10)
  [#[1, 9, 2, 0, 0, 0], #[1, 9, 4, 0, 1, 0, 23, 0],
      #[1, 9, 6, 0, 2, 0, 4, 0, 5, 0]].do: | reject/ByteArray |
    expect-equals 1 (signaling.parameter-response reject 9)
    expect-null (signaling.response reject)
  [#[1, 9, 2, 0, 1, 0], #[1, 9, 4, 0, 2, 0, 4, 0],
      #[0x13, 9, 2, 0, 2, 0]].do: | invalid/ByteArray |
    expect-throw "L2CAP_INVALID_SIGNALING": signaling.parameter-response invalid 9

check packet/ByteArray:
  original := packet.copy
  [false, true].do: | peripheral/bool |
    failure := catch:
      reply := signaling.response packet --peripheral=peripheral
      if reply:
        expect (reply.size == 6 or reply.size == 8)
        expect-equals packet[1] reply[1]
        expect-equals (reply.size - 4) (io.LITTLE-ENDIAN.uint16 reply 2)
        // A rejection must never cause a response loop.
        expect-equals null (signaling.response reply)
    if failure: expect-equals "L2CAP_INVALID_SIGNALING" failure
  failure := catch:
    result := signaling.parameter-response packet 7
    expect (result == null or result == 0 or result == 1)
  if failure: expect-equals "L2CAP_INVALID_SIGNALING" failure
  failure = catch:
    request := signaling.decode-parameter-request packet
    if request:
      expect-equals 12 packet.size
      expect-equals 0x12 packet[0]
      expect (request.identifier != 0)
      // Exercise range checking even for structurally valid hostile values.
      if request.valid:
        expect (6 <= request.interval-min <= request.interval-max <= 3200)
        expect (0 <= request.latency <= 499)
        expect (10 <= request.supervision-timeout <= 3200)
        expect (request.supervision-timeout * 4 >
            (request.latency + 1) * request.interval-max)
  if failure: expect-equals "L2CAP_INVALID_SIGNALING" failure
  expect-equals original packet
