// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.native
import ble.experimental.linux-management
import encoding.hex

// Development fixture only. This is the public Core D.7 IRK in wire order.
FIXTURE-IRK ::= #[0x9b, 0x7d, 0x39, 0x0a, 0xa6, 0x10, 0x10, 0x34,
                 0x05, 0xad, 0xc8, 0x57, 0xa3, 0x34, 0x02, 0xec]

main args/List:
  if args.size != 3:
    throw "Usage: hci-management.toit <index> <expected address> <info|power-on|power-off|fixture-privacy-on|fixture-privacy-off>"
  adapter := int.parse args[0]
  expected := hex.decode (args[1].replace --all ":" "")
  action := args[2]
  if not ["info", "power-on", "power-off", "fixture-privacy-on", "fixture-privacy-off"].contains action:
    throw "INVALID_ARGUMENT"
  client := linux-management.Client (native.NativeTransport.management) adapter
  try:
    original := client.info
    if expected.size != 6 or original.address.reverse != expected:
      throw "MGMT_WRONG_ADAPTER"
    if action == "info":
      print "MGMT address=$(hex.encode original.address.reverse) powered=$(original.powered) privacy=$(original.privacy)"
      return
    if action == "power-on" or action == "power-off":
      client.set-powered (action == "power-on")
      return
    if action == "fixture-privacy-on" and original.privacy:
      throw "MGMT_PRIVACY_ALREADY_ENABLED"
    try:
      client.set-powered false
      client.set-privacy (action == "fixture-privacy-on" ? 1 : 0) FIXTURE-IRK
    finally:
      // Open a fresh channel in case the failed command closed the old one.
      restore := linux-management.Client (native.NativeTransport.management) adapter
      try:
        if restore.info.address != original.address: throw "MGMT_WRONG_ADAPTER"
        restore.set-powered original.powered
      finally:
        restore.close
    state := client.info
    if state.privacy != (action == "fixture-privacy-on"): throw "MGMT_PRIVACY_NOT_SET"
    print "MGMT powered=$(state.powered) privacy=$(state.privacy)"
  finally:
    client.close
