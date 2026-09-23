// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system.storage
import ble.experimental.storage-key show StorageKey

PATH ::= "toit.io/test/ble-storage-key"

main:
  StorageKey.clear --path=PATH
  expect-throw "BLE_STORAGE_KEY_MISSING": StorageKey.load --path=PATH
  key := StorageKey.provision --path=PATH
  expect-equals 32 key.size
  // Provisioning again keeps the key; loading returns the same bytes.
  expect-equals key (StorageKey.provision --path=PATH)
  expect-equals key (StorageKey.load --path=PATH)
  expect (key != (ByteArray 32))
  // Anything but a 32-byte key is refused, not repaired.
  bucket := storage.Bucket.open --flash PATH
  bucket["key"] = #[1, 2, 3]
  bucket.close
  expect-throw "BLE_STORAGE_KEY_CORRUPT": StorageKey.load --path=PATH
  expect-throw "BLE_STORAGE_KEY_CORRUPT": StorageKey.provision --path=PATH
  StorageKey.clear --path=PATH
  expect-throw "BLE_STORAGE_KEY_MISSING": StorageKey.load --path=PATH
