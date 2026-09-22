// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.bond-info show BondInfo
import ble.experimental.service.bond-admin-client as admin
import encoding.hex

// Run in the administrator container selected by trusted provider startup code.
// The PID comes from that trusted launcher; discovery alone grants no access.
main args/List:
  if args.size != 1: throw "Usage: service-bonds.toit <trusted provider PID>"
  client := admin.Client --provider-pid=(int.parse args[0])
  client.open --timeout=(Duration --s=5)
  try:
    client.bonds.do: | info/BondInfo |
      print "slot=$(info.slot) peer=$(hex.encode info.peer-address.reverse) type=$(info.peer-address-type) authenticated-pairing=$(info.authenticated)"
  finally:
    client.close
