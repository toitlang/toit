// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import rpc
import uuid
import serialization show serialize deserialize
import drivers.cellular

/**
Functionality available on devices (ESP32).
*/

RPC_SYSTEM_DEVICE_NAME ::= 100
RPC_SYSTEM_DEVICE_HARDWARE_ID ::= 101
RPC_SYSTEM_FLASHSTORE_GET ::= 102
RPC_SYSTEM_FLASHSTORE_SET ::= 103
RPC_SYSTEM_FLASHSTORE_DELETE ::= 104
RPC_SYSTEM_CONSOLE_CONNECTION_OPEN ::= 105
RPC_SYSTEM_CONSOLE_CONNECTION_CLOSE ::= 106
RPC_SYSTEM_ESTIMATE_TIME_ACCURACY ::= 107
RPC_SYSTEM_GNSS_START ::= 108
RPC_SYSTEM_GNSS_LOCATION ::= 109
RPC_SYSTEM_GNSS_STOP ::= 110

/** Name of this device. */
name -> string?:
  return rpc.invoke RPC_SYSTEM_DEVICE_NAME []

/** Hardware ID of this device. */
hardware_id/uuid.Uuid ::= uuid.Uuid
  rpc.invoke RPC_SYSTEM_DEVICE_HARDWARE_ID []

/**
Estimated time accuracy of this device.

On the device, the time drifts. The time is corrigated using the NTP when the
  devices goes online. The estimated time accuracy is the estimated time
  accuracy when the time was last set plus the an estimated time drift.
*/
estimate_time_accuracy -> int?:
  return rpc.invoke RPC_SYSTEM_ESTIMATE_TIME_ACCURACY []

/** Simple key-value store. */
interface Store:
  get name/string
  delete name/string
  set name/string value/any

/**
Flash backed key-value store.

Key-value pairs are persisted in the flash, so they can be accessed across
  deep sleeps.
Make sure to remove obsolete key-value pairs using $delete.

The store is cleared on firmware updates.
*/
class FlashStore implements Store:
  /**
  Gets the value for the given $key.

  Returns null if no value is available.
  */
  get key/string -> any:
    res := rpc.invoke RPC_SYSTEM_FLASHSTORE_GET [key]
    if res is ByteArray:
        return deserialize res
    return null

  /**
  Deletes the given $key from the store.

  The $key does not need to be present in the store.
  */
  delete key/string:
    rpc.invoke RPC_SYSTEM_FLASHSTORE_DELETE [key]

  /**
  Inserts the given $key-$value pair in the store.

  If the $key already exists in the store, then the value is overwritten.
  */
  set key/string value/any:
    rpc.invoke RPC_SYSTEM_FLASHSTORE_SET [key, serialize value]

/**
Connection to the console.

Forces the kernel to attempt to connect to the console.
*/
class ConsoleConnection extends rpc.CloseableProxy:
  /** Opens a connection to the console. */
  constructor.open:
    super
      rpc.invoke RPC_SYSTEM_CONSOLE_CONNECTION_OPEN []

  close_rpc_selector_: return RPC_SYSTEM_CONSOLE_CONNECTION_CLOSE

/**
Control of the GNSS module controlled by the kernel.
*/
class Gnss extends rpc.CloseableProxy:
  /**
  Starts GNSS.

  The device must support GNSS.
  */
  constructor.start:
    super
      rpc.invoke RPC_SYSTEM_GNSS_START []

  close_rpc_selector_: return RPC_SYSTEM_GNSS_STOP

  /**
  The location of this device.

  Returns null if there is no location fix.
  */
  location -> cellular.GnssLocation?:
    bytes := rpc.invoke RPC_SYSTEM_GNSS_LOCATION [handle_]
    if not bytes: return null
    return cellular.GnssLocation.deserialize bytes
