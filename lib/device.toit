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
hardware-id/uuid.Uuid ::= uuid.Uuid.uuid5 "hw_id" get-mac-address_

// --------------------------------------------------------------------------

get-mac-address_:
  #primitive.esp32.get-mac-address
