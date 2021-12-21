// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import drivers.cellular
import device
import encoding.ubjson
import uuid

/**
Implementation of ESP32 device library. Use the APIs in the device library.
*/
class Device_ implements device.Device_:
  static instance_/Device_? := null
  static hardware_id_/uuid.Uuid? := null

  constructor.instance:
    if not instance_: instance_ = Device_.init_

    return instance_

  constructor.init_:

  name -> string?:
    return get_mac_address_.stringify

  hardware_id -> uuid.Uuid:
    if not hardware_id_: hardware_id_ = uuid.uuid5 "hw_id" get_mac_address_
    return hardware_id_

  estimate_time_accuracy -> int?:
    throw "NOT IMPLEMENTED"

class FlashStore_ implements device.Store:
  static instance_/FlashStore_? := null

  kv_store_ ::= KeyValue_
      Volume_.init_ "nvs" false
      "kv store"

  constructor.instance:
    if not instance_: instance_ = FlashStore_.init_

    return instance_

  constructor.init_:

  get key/string -> any:
    bytes := kv_store_.bytes key
    if not bytes: return null

    return ubjson.decode bytes

  delete key/string:
    return kv_store_.delete key

  set key/string value/any:
    bytes := ubjson.encode value
    return kv_store_.set_bytes key bytes

class ConsoleConnection_:
  constructor.open:
    throw "NOT IMPLEMENTED"

class Gnss_:
  constructor.start:
    throw "NOT IMPLEMENTED"

  location -> cellular.GnssLocation?:
    throw "NOT IMPLEMENTED"

get_mac_address_:
  #primitive.esp32.get_mac_address

class Volume_:
  name_/string ::= ?
  read_only_/bool ::= ?

  constructor.init_ .name_ .read_only_:

  from name -> KeyValue_:
    return KeyValue_ this name

class KeyValue_:
  group_ ::= ?

  constructor volume name:
    group_ = flash_kv_init_ volume.name_ name volume.read_only_

  bytes key:
    return flash_kv_read_bytes_ group_ key

  set_bytes key value:
    return flash_kv_write_bytes_ group_ key value

  set_string key value:
    return flash_kv_write_bytes_ group_ key value.to_byte_array

  delete key:
    return flash_kv_delete_ group_ key

flash_kv_init_ volume name read_only:
  #primitive.flash_kv.init

flash_kv_read_bytes_ resource_group key:
  #primitive.flash_kv.read_bytes

flash_kv_write_bytes_ resource_group key value:
  #primitive.flash_kv.write_bytes

flash_kv_delete_ resource_group key:
  #primitive.flash_kv.delete
