// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.linux
import encoding.hex
import .bounded-radio as fixture
import .bounded-reverse as reverse

main args/List:
  if args.size != 2: throw "Usage: bounded-reverse-linux.toit <adapter index> <public owner address>"
  peer := (hex.decode (args[1].replace --all ":" "")).reverse
  controller := hci.Controller (linux.LinuxTransport (int.parse args[0]))
  host/central.Central? := null
  client/att.Client? := null
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    link := host.connect peer --address-type=0 --timeout=(Duration --s=30)
    client = att.Client host link
    2.repeat: | cycle/int |
      fixture.read-values client
      with-timeout --ms=30_000:
        while (client.read reverse.CONTROL-HANDLE) != #[cycle + 1]: sleep --ms=10
      fixture.read-values client
      client.write reverse.CONTROL-HANDLE #[cycle + 1]
      print "BOUNDED_REVERSE_PEER CYCLE cycle=$cycle reads=$((cycle + 1) * 200)"
    host.disconnect link
    link.wait-disconnected
    print "BOUNDED_REVERSE_PEER COMPLETE reads=400"
  finally:
    if client: client.close
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
