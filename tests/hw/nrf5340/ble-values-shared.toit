// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import ble

SERVICE ::= ble.BleUuid "97fb0010-837a-4de0-9105-ff287aac1051"
LONG ::= ble.BleUuid "97fb0011-837a-4de0-9105-ff287aac1051"
REQUEST ::= ble.BleUuid "97fb0012-837a-4de0-9105-ff287aac1051"
COMMAND ::= ble.BleUuid "97fb0013-837a-4de0-9105-ff287aac1051"
EMPTY ::= ble.BleUuid "97fb0014-837a-4de0-9105-ff287aac1051"
SLOW ::= ble.BleUuid "97fb0015-837a-4de0-9105-ff287aac1051"
ENCRYPTED ::= ble.BleUuid "97fb0016-837a-4de0-9105-ff287aac1051"

long-value -> ByteArray:
  return ByteArray 512: (it * 17 + 3) & 255
