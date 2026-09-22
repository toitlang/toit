// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.smp-pairing as smp
import crypto.sha256 show sha256
import encoding.hex
import expect show *
import io
import system

main args/List:
  args.do: expect (["responder", "numeric", "display", "bad-dhkey", "bad-public-key", "zero-y", "one-y", "flip-y", "same-x"].contains it)
  initiator := not (args.contains "responder")
  numeric := args.contains "numeric"
  bad-dhkey := args.contains "bad-dhkey"
  bad-public-key := args.contains "bad-public-key"
  zero-y := args.contains "zero-y"
  one-y := args.contains "one-y"
  flip-y := args.contains "flip-y"
  same-x := args.contains "same-x"
  expect (not same-x or (initiator and bad-public-key and not zero-y and not one-y and not flip-y))
  expect (not (zero-y and one-y))
  expect (bad-public-key or not (zero-y or one-y))
  expect (not flip-y or (bad-public-key and not zero-y and not one-y))
  expect (not (numeric and bad-dhkey))
  expect (not (bad-public-key and (numeric or bad-dhkey)))
  a := #[0, 1, 2, 3, 4, 5, 6]
  b := #[1, 6, 5, 4, 3, 2, 1]
  with-timeout --ms=10_000:
    session := smp.Session --initiator=initiator --io-capability=(numeric or args.contains "display" ? 1 : 3)
        --require-authentication=numeric
        --local-address=(initiator ? a : b)
        --peer-address=(initiator ? b : a)
    input := io.stdin
    local-public/ByteArray? := null
    try:
      if initiator: (session.start).do: print (hex.encode it)
      while not session.verified:
        line := input.read-line
        if not line: throw "SMP_PEER_EXITED"
        packet := hex.decode line
        code := packet[0]
        if bad-public-key and code == 0x0c:
          expect-equals 65 packet.size
          if same-x:
            expect-not-null local-public
            expect-equals local-public[..32] packet[1..33]
            expect (local-public[32..] != packet[33..])
          else if zero-y or one-y:
            expect-equals (one-y ? 1 : 0) packet[33]
            expect-equals (ByteArray 31) packet[34..]
          else if not flip-y:
            expect-equals (#[0x0c] + (ByteArray 64)) packet
          outgoing := session.receive packet
          expect-equals [#[5, 0x0b]] outgoing
          packet.fill 0
          system.process-stats --gc
          expect-equals "failed" session.state
          expect-equals 0x0b session.failure
          expect-equals null session.deadline
          expect (not session.verified and not session.authenticated and not session.bonding)
          expect-throw "SMP_KEY_NOT_READY": session.key
          expect-throw "SMP_INVALID_STATE": session.receive #[0x0c]
          outgoing.do: print (hex.encode it)
          print "PUBLIC-KEY-REJECTED"
          return
        outgoing := session.receive packet
        packet.fill 0
        system.process-stats --gc
        outgoing.do: | pdu/ByteArray |
          if pdu[0] == 0x0c: local-public = pdu[1..].copy
          print (hex.encode pdu)
        if session.failure:
          expect bad-dhkey
          expect-equals 0x0d code
          expect-equals 0x0b session.failure
          expect-equals "failed" session.state
          expect-equals 1 outgoing.size
          expect-equals #[5, 0x0b] outgoing[0]
          expect (not session.verified and not session.authenticated and not session.bonding)
          expect-throw "SMP_KEY_NOT_READY": session.key
          expect-equals null session.deadline
          expect-throw "SMP_INVALID_STATE": session.receive #[0x0d]
          print "DHKEY-REJECTED"
          return
        if session.state == "approval":
          expect numeric
          expect (not session.verified and not session.authenticated)
          expect-throw "SMP_KEY_NOT_READY": session.key
          print "NUMBER $(session.comparison-number)"
          decision := input.read-line
          expect (decision == "approve" or decision == "reject")
          (session.approve (decision == "approve")).do: print (hex.encode it)
          if decision == "reject":
            expect-equals "failed" session.state
            expect-equals 0x0c session.failure
            expect (not session.verified and not session.authenticated and not session.bonding)
            expect-throw "SMP_KEY_NOT_READY": session.key
            expect-equals null session.deadline
            print "REJECTED"
            return
      expect-equals numeric session.authenticated
      expect (not bad-dhkey and not bad-public-key)
      expect (not session.bonding)
      // Compare ephemeral test keys through a digest, without logging the LTK.
      print "KEY-DIGEST $(hex.encode (sha256 session.key))"
    finally:
      session.close
