// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
A bond-protection key kept in device flash across restarts.

`bond-protection.Protection` seals bond records with a caller-supplied
  32-byte key. This helper gives a deployment a device-unique random key that
  survives provider restarts and reboots, created once at provisioning time
  and only loaded afterwards, so a missing key stops admission instead of
  silently starting over with fresh pairings (docs/ble/deployment.md).

What it does not do: the key lives in ordinary flash storage, so its secrecy
  is that of the flash. A deployment that needs more enables flash encryption
  and secure boot, or replaces this with its own key source. Erasing the key
  makes every record sealed with it unreadable; there is no recovery.
*/

import crypto
import system.storage

class StorageKey:
  static DEFAULT-PATH ::= "toit.io/ble/storage-key"
  static KEY ::= "key"
  static SIZE ::= 32

  /**
  Returns the provisioned key, creating it from the system random source
    when none exists yet. Call from a provisioning step, not from routine
    provider startup; see $load.
  */
  static provision --path/string=DEFAULT-PATH -> ByteArray:
    bucket := storage.Bucket.open --flash path
    try:
      existing := bucket.get KEY --if-absent=: null
      if existing: return check_ existing
      key := crypto.random --size=SIZE
      bucket[KEY] = key
      return key
    finally:
      bucket.close

  /**
  Returns the provisioned key.

  Throws BLE_STORAGE_KEY_MISSING when none was provisioned, so a provider
    started without its key refuses bonded admission rather than overwriting
    records or pairing afresh.
  */
  static load --path/string=DEFAULT-PATH -> ByteArray:
    bucket := storage.Bucket.open --flash path
    try:
      existing := bucket.get KEY --if-absent=: null
      if not existing: throw "BLE_STORAGE_KEY_MISSING"
      return check_ existing
    finally:
      bucket.close

  /** Removes the key; records sealed with it become unreadable. */
  static clear --path/string=DEFAULT-PATH -> none:
    bucket := storage.Bucket.open --flash path
    try:
      bucket.remove KEY
    finally:
      bucket.close

  static check_ value -> ByteArray:
    if value is not ByteArray or value.size != SIZE: throw "BLE_STORAGE_KEY_CORRUPT"
    return value
