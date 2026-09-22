// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.linux
import ble.experimental.transport
import encoding.hex
import .bounded-radio as fixture

main args/List:
  if not 2 <= args.size <= 3: throw "Usage: mixed-service-linux.toit <adapter index> <public provider address> [cycles]"
  cycles := args.size == 3 ? (int.parse args[2]) : 4
  if not 1 <= cycles <= 4: throw "INVALID_ARGUMENT"
  peer := (hex.decode (args[1].replace --all ":" "")).reverse
  run (linux.LinuxTransport (int.parse args[0])) peer --cycles=cycles

run radio/transport.Transport peer/ByteArray --cycles/int=4:
  if not 1 <= cycles <= 4: throw "INVALID_ARGUMENT"
  controller := hci.Controller radio
  host/central.Central? := null
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    cycles.repeat: | cycle/int |
      link := host.connect peer --address-type=0 --timeout=(Duration --s=40)
      client := att.Client host link
      try:
        fixture.read-values client
        client.write 12 #[1]
        reason := with-timeout --ms=30_000: link.wait-disconnected
        if reason != 0x13: throw "MIXED_PEER_DISCONNECT_REASON"
        print "MIXED_LINUX CYCLE cycle=$cycle reads=100 reason=$reason"
      finally:
        client.close
    print "MIXED_LINUX COMPLETE reads=$(cycles * 100)"
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
