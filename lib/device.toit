// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import uuid
import encoding.tison

import system.storage  // For toitdoc.

/**
Functionality available on devices (ESP32).
*/

/** Name of this device. */
name -> string:
  return hardware_id.stringify

/** Hardware ID of this device. */
hardware_id/uuid.Uuid ::= uuid.uuid5 "hw_id" get_mac_address_

/**
Simple key-value store.

Deprecated. Use $storage.Bucket instead.
*/
interface Store:
  get name/string -> any
  delete name/string -> none
  set name/string value/any -> none

/**
Flash backed key-value store.

Key-value pairs are persisted in the flash, so they can be accessed across
  deep sleeps.

Make sure to remove obsolete key-value pairs using $delete.

Deprecated. Use $storage.Bucket instead.
*/
class FlashStore implements Store:
  static instance_/FlashStore ::= FlashStore.internal_
  group_ ::= ?

  constructor:
    return instance_

  constructor.internal_:
    group_ = flash_kv_init_ "nvs" "kv store" false

  /**
  Gets the value for the given $key.

  Returns null if no value is available.
  */
  get key/string -> any:
    bytes := flash_kv_read_bytes_ group_ key
    return bytes ? (tison.decode bytes) : null

  /**
  Deletes the given $key from the store.

  The $key does not need to be present in the store.
  */
  delete key/string -> none:
    flash_kv_delete_ group_ key

  /**
  Inserts the given $key-$value pair in the store.

  If the $key already exists in the store, then the value is overwritten.

  The $value is encoded as TISON. As such it supports:
  - literals: numbers, booleans, strings, null.
  - lists.
  - maps. The keys must be strings, and the values must be valid TISON objects.
  */
  set key/string value/any -> none:
    flash_kv_write_bytes_ group_ key (tison.encode value)

// --------------------------------------------------------------------------

get_mac_address_:
  #primitive.esp32.get_mac_address

flash_kv_init_ volume name read_only:
  #primitive.flash_kv.init

flash_kv_read_bytes_ resource_group key:
  #primitive.flash_kv.read_bytes

flash_kv_write_bytes_ resource_group key value:
  #primitive.flash_kv.write_bytes

flash_kv_delete_ resource_group key:
  #primitive.flash_kv.delete
