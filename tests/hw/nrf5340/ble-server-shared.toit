// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import ble

SERVICE ::= ble.BleUuid "97fb0030-837a-4de0-9105-ff287aac1051"
LONG ::= ble.BleUuid "97fb0031-837a-4de0-9105-ff287aac1051"
EMPTY ::= ble.BleUuid "97fb0032-837a-4de0-9105-ff287aac1051"
REQUEST ::= ble.BleUuid "97fb0033-837a-4de0-9105-ff287aac1051"
COMMAND ::= ble.BleUuid "97fb0034-837a-4de0-9105-ff287aac1051"
NOTIFY ::= ble.BleUuid "97fb0035-837a-4de0-9105-ff287aac1051"
INDICATE ::= ble.BleUuid "97fb0036-837a-4de0-9105-ff287aac1051"
CONTROL ::= ble.BleUuid "97fb0037-837a-4de0-9105-ff287aac1051"
ENCRYPTED ::= ble.BleUuid "97fb0038-837a-4de0-9105-ff287aac1051"
DESCRIPTOR ::= ble.BleUuid "97fb0039-837a-4de0-9105-ff287aac1051"

payload length/int seed/int -> ByteArray:
  return ByteArray length: (seed + it * 19) & 255

name cycle/int epoch/int -> string:
  return "toit-nrf-srv-$cycle-$epoch"
