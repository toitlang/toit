// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import drivers.cellular
import device
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

  constructor.instance:
    if not instance_: instance_ = FlashStore_.init_

    return instance_

  constructor.init_:

  get key/string -> any:
    throw "NOT IMPLEMENTED"

  delete key/string:
    throw "NOT IMPLEMENTED"

  set key/string value/any:
    throw "NOT IMPLEMENTED"

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
