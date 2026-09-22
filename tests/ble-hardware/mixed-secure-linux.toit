// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.linux
import ble.experimental.security
import ble.experimental.transport
import encoding.hex
import .mixed-service-client as fixture

main args/List:
  if args.size != 2: throw "Usage: mixed-secure-linux.toit <adapter index> <public provider address>"
  address := (hex.decode (args[1].replace --all ":" "")).reverse
  run (linux.LinuxTransport (int.parse args[0])) address

run radio/transport.Transport address/ByteArray:
  controller := hci.Controller radio
  host/central.Central? := null
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    4.repeat: | cycle/int |
      link := host.connect address --address-type=0 --timeout=(Duration --s=40)
      pairing := security.Pairing host link --local-address=info.address
          --io-capability=1
          --require-authentication
      client := att.Client host link --pairing=pairing
      try:
        error := catch: client.read 12
        if not (error is att.AttributeError) or error.code != 5: throw "MIXED_EXPECTED_PROTECTED_DENIAL"
        pairing.run: | number/int |
          print "MIXED_SECURE_LINUX NUMERIC cycle=$cycle value=$number fixture-approval=true"
          true
        fixture.check-values:
          if not pairing.encrypted or not pairing.authenticated: throw "MIXED_SECURITY_LOST"
          client.read 12
        // This command asks the application to close immediately. Its observed
        // disconnect is the acknowledgement; no ATT reply may race that close.
        client.write-command 14 #[1]
        reason := with-timeout --ms=30_000: link.wait-disconnected
        if reason != 0x13: throw "MIXED_PEER_DISCONNECT_REASON"
        print "MIXED_SECURE_LINUX CYCLE cycle=$cycle protected-reads=100 denied=1 reason=$reason"
      finally:
        client.close
    print "MIXED_SECURE_LINUX COMPLETE protected-reads=400 denied=4"
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
