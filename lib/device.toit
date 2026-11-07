// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import uuid
import encoding.tison
import rp2350
import rp2040
import system

import system.storage  // For toitdoc.

/**
Functionality available on devices (ESP32, RP2040 and RP2350).
*/

/** Name of this device. */
name -> string:
  return hardware-id.stringify

/** Hardware ID of this device. */
hardware-id/uuid.Uuid ::= uuid.Uuid.uuid5 "hw_id" get-hardware-id_

// --------------------------------------------------------------------------

get-hardware-id_:
  if system.architecture == system.ARCHITECTURE-RP2350:
    return rp2350.unique-id
  if system.architecture == system.ARCHITECTURE-RP2040:
    return rp2040.unique-id
  return get-mac-address_

get-mac-address_:
  #primitive.esp32.get-mac-address
