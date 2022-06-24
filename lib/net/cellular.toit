// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import system.api.cellular show CellularServiceClient CellularWiring

import .impl

export CellularWiring

service_/CellularServiceClient? ::= (CellularServiceClient --no-open).open

open -> net.Interface
    --wiring/CellularWiring
    --apn/string
    --bands/List?=null
    --rats/List?=null:
  service := service_
  if not service: throw "cellular unavailable"
  return SystemInterface_ service (service.connect wiring apn bands rats)
