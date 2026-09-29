// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ble.experimental.transport as transport
import ble.experimental.service.gatt-provider as providers
import ble.experimental.service.client as clients

main:
  with-timeout --ms=5_000:
    provider := Provider
    provider.install
    client := clients.Client
    client.open
    try:
      expect-throw "INVALID_ARGUMENT": client.configure --name="This name is longer than twenty bytes"
      expect-throw "INVALID_ARGUMENT": client.configure --handler-timeout=(Duration --us=0)
      expect-throw "INVALID_ARGUMENT": client.configure --handler-timeout=(Duration --us=10_000_001)
      session := client.configure --name="Application"
      expect-throw "INVALID_ARGUMENT": session.set-handler-timeout (Duration --us=0)
      expect-throw "INVALID_ARGUMENT": session.set-handler-timeout (Duration --us=10_000_001)
      session.set-handler-timeout (Duration --s=10)
      session.set-handler-timeout (Duration --s=1)
      expect-equals 0 provider.opened
      expect-throw "GATT_SERVICE_BUSY": client.configure
      expect-throw "GATT_NOT_STARTED": session.peer
      expect-throw "GATT_NOT_STARTED": session.next
      expect-equals 14 (session.add-service #[0xf0, 0xff])
      expect-throw "INVALID_ARGUMENT": session.add-characteristic #[0xf1, 0xff] --dynamic-read
      value := #[1, 2]
      handle := session.add-characteristic #[0xf1, 0xff]
          --read
          --write
          --notify
          --dynamic-read
          --validate-write
          --value=value
      expect-equals 16 handle
      value[0] = 99
      expect-equals #[1, 2] (session.value handle)
      snapshot := session.value handle
      snapshot[0] = 98
      expect-equals #[1, 2] (session.value handle)
      expect-throw "INVALID_ARGUMENT": session.set-value handle (ByteArray 21)
      expect-throw "INVALID_ARGUMENT": session.start (ByteArray 32)
      expect-throw "INVALID_ARGUMENT": session.start #[] --scan-response=(ByteArray 32)
      expect-equals 0 provider.opened
      expect-equals 19 (session.add-characteristic #[0xf2, 0xff] --read)
      description := session.add-descriptor 19 #[1, 0x29] --value=#[65]
      expect-equals 20 description
      expect-equals #[65] (session.value description)
      session.set-value description #[66]
      expect-equals #[66] (session.value description)
      expect-throw "GATT_RESERVED_DESCRIPTOR": session.add-descriptor 19 #[2, 0x29]
      expect-throw "INVALID_ARGUMENT": session.add-descriptor 16 #[0xf1, 0xff]
      expect-throw "INVALID_ARGUMENT": session.start #[] --interval=31
      expect-throw "INVALID_ARGUMENT": session.start #[] --interval=16385
      expect-equals 0 provider.opened
      session.start #[2, 1, 6]
      expect-throw "GATT_DATABASE_SEALED": session.set-handler-timeout (Duration --s=2)
      expect-throw "GATT_DATABASE_SEALED": session.add-service #[0xf3, 0xff]
      expect-throw "GATT_DATABASE_SEALED": session.add-descriptor 19 #[0xf1, 0xff]
      expect-throw "GATT_DATABASE_SEALED": session.start #[]
      expect-throw "TEST_OPEN_FAILED": session.peer
      expect-equals 1 provider.opened
      session.close
      expect-throw "GATT_REQUESTS_CLOSED": session.value handle
      expect-throw "GATT_REQUESTS_CLOSED": session.security
      // Closing a never-started builder must release the sole session slot.
      second := client.configure
      second.close
      expect-throw "GATT_REQUESTS_CLOSED": second.add-service #[0xf0, 0xff]
      third := client.configure
      third.add-service #[0xf0, 0xff]
      27.repeat: third.add-characteristic #[0xf1, 0xff] --read
      expect-throw "GATT_DATABASE_FULL": third.add-characteristic #[0xf2, 0xff] --read
      third.close
      expect-equals 1 provider.opened
    finally:
      client.close
      provider.uninstall

class Provider extends providers.Provider:
  opened/int := 0

  constructor:
    super

  open-transport -> transport.Transport:
    opened++
    throw "TEST_OPEN_FAILED"
