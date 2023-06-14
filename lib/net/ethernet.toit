// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import system.api.ethernet show EthernetServiceClient

service_/EthernetServiceClient? := null
service_initialized_/bool := false

open config/Map -> net.Client
    --name/string?=null:
  if not service_initialized_:
    // We typically run the ethernet service in a non-system
    // container with --trigger=boot, so we need to give it
    // time to start so it can be discovered. We should really
    // generalize this handling for net.open and wifi.open too,
    // so we get a shared pattern for dealing with discovering
    // such network services at start up.
    service_initialized_ = true
    service_ = (EthernetServiceClient).open
        --timeout=(Duration --s=5)
        --if_absent=: null
  service := service_
  if not service: throw "ethernet unavailable"
  return net.Client service --name=name (service.connect config)
