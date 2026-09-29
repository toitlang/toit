// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The Toit side of bumble-passkey.py: one Passkey Entry exchange over pipes.
// Usage: smp-passkey.toit <initiator|responder> <io capability>

import ble.experimental.smp-pairing as smp
import crypto.sha256 show sha256
import encoding.hex
import io

main args/List:
  initiator := args[0] == "initiator"
  capability := int.parse args[1]
  a := #[0, 1, 2, 3, 4, 5, 6]
  b := #[1, 6, 5, 4, 3, 2, 1]
  with-timeout --ms=15_000:
    session := smp.Session --initiator=initiator --io-capability=capability
        --require-authentication
        --local-address=(initiator ? a : b)
        --peer-address=(initiator ? b : a)
    input := io.stdin
    shown := false
    try:
      if initiator: (session.start).do: print (hex.encode it)
      while not session.verified and session.state != "failed":
        if not shown and session.passkey-display:
          print "PASSKEY $session.passkey-display"
          shown = true
        line := input.read-line
        if not line: throw "SMP_PEER_EXITED"
        outgoing := line.starts-with "passkey "
            ? session.enter-passkey (int.parse line[8..])
            : session.receive (hex.decode line)
        outgoing.do: print (hex.encode it)
        if not shown and session.passkey-display:
          print "PASSKEY $session.passkey-display"
          shown = true
      if session.verified:
        if not session.authenticated: throw "NOT_AUTHENTICATED"
        print "KEY-DIGEST $(hex.encode (sha256 session.key))"
      else:
        print "FAILED $session.failure"
    finally:
      session.close
