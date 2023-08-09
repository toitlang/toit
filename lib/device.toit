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
  return hardware-id.stringify

/** Hardware ID of this device. */
hardware-id/uuid.Uuid ::= uuid.uuid5 "hw_id" get-mac-address_

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
    group_ = flash-kv-init_ "nvs" "kv store" false

  /**
  Gets the value for the given $key.

  Returns null if no value is available.
  */
  get key/string -> any:
    bytes := flash-kv-read-bytes_ group_ key
    return bytes ? (tison.decode bytes) : null

  /**
  Deletes the given $key from the store.

  The $key does not need to be present in the store.
  */
  delete key/string -> none:
    flash-kv-delete_ group_ key

  /**
  Inserts the given $key-$value pair in the store.

  If the $key already exists in the store, then the value is overwritten.

  The $value is encoded as TISON. As such it supports:
  - literals: numbers, booleans, strings, null.
  - lists.
  - maps. The keys must be strings, and the values must be valid TISON objects.
  */
  set key/string value/any -> none:
    flash-kv-write-bytes_ group_ key (tison.encode value)

// --------------------------------------------------------------------------

get-mac-address_:
  #primitive.esp32.get-mac-address

flash-kv-init_ volume name read-only:
  #primitive.flash-kv.init

flash-kv-read-bytes_ resource-group key:
  #primitive.flash-kv.read-bytes

flash-kv-write-bytes_ resource-group key value:
  #primitive.flash-kv.write-bytes

flash-kv-delete_ resource-group key:
  #primitive.flash-kv.delete
