// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import monitor
import system.api.wifi show WifiServiceClient

import .impl

service_value_/WifiServiceClient? := null
service_mutex_/monitor.Mutex ::= monitor.Mutex

service_ -> WifiServiceClient?:
  return service_value_ or service_mutex_.do:
    service_value_ = (WifiServiceClient --no-open).open

open --ssid/string --password/string -> net.Interface:
  service := service_
  if not service: throw "WiFi unavailable"
  return SystemInterface_ service (service.connect ssid password)
