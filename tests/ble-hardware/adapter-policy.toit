// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.linux-management
import ble.experimental.native
import encoding.hex

// Invoked under the native supervisor's lock. Stdout is a single state token.
// Every invocation uses the caller's existing CAP_NET_ADMIN grant.
main args/List:
  if args.size != 3: throw "Usage: adapter-policy INDEX EXPECTED_ADDRESS state|power-on|power-off"
  adapter := int.parse args[0]
  expected := hex.decode (args[1].replace --all ":" "")
  powered := configure adapter expected args[2]: native.NativeTransport.management
  print (powered ? "on" : "off")

// The scoped transport factory allows fault tests to exercise the actual
// management protocol without opening a host socket or retaining a lambda.
configure adapter/int expected/ByteArray mode/string [open] -> bool:
  if not 0 <= adapter < 0xffff or expected.size != 6: throw "INVALID_ARGUMENT"
  if not ["state", "power-on", "power-off"].contains mode: throw "INVALID_ARGUMENT"
  expected = expected.copy
  with-timeout --ms=8000:
    while true:
      client := linux-management.Client open.call adapter
      result/bool? := null
      error := catch:
        try:
          before := client.info
          if before.address.reverse != expected: throw "MGMT_WRONG_ADAPTER"
          if mode == "state":
            result = before.powered
          else:
            wanted := mode == "power-on"
            if before.powered != wanted: client.set-powered wanted
            after := client.info
            if after.address.reverse != expected: throw "MGMT_WRONG_ADAPTER"
            if after.powered != wanted: throw "MGMT_POWER_NOT_VERIFIED"
            result = after.powered
        finally:
          client.close
      if not error:
        return result
      if mode == "state" or error == "MGMT_WRONG_ADAPTER": throw error
      // A user-channel close can leave controller teardown in progress. Retry
      // with a fresh management channel and a fresh identity check each time.
      sleep --ms=200
  unreachable
