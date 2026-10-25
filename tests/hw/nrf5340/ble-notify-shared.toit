// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import ble

SERVICE ::= ble.BleUuid "97fb0020-837a-4de0-9105-ff287aac1051"
NOTIFY ::= ble.BleUuid "97fb0021-837a-4de0-9105-ff287aac1051"
INDICATE ::= ble.BleUuid "97fb0022-837a-4de0-9105-ff287aac1051"
TRIGGER ::= ble.BleUuid "97fb0023-837a-4de0-9105-ff287aac1051"
COMPLETED ::= ble.BleUuid "97fb0024-837a-4de0-9105-ff287aac1051"

payload length/int seed/int -> ByteArray:
  return ByteArray length: (seed + it * 17) & 255
