// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import system.api.wifi show WifiServiceClient

import .impl

CONFIG_SSID      /string ::= "ssid"
CONFIG_PASSWORD  /string ::= "password"

CONFIG_BROADCAST /string ::= "broadcast"
CONFIG_CHANNEL   /string ::= "channel"

OPEN_KEYS_      /List ::= [CONFIG_SSID, CONFIG_PASSWORD]
ESTABLISH_KEYS_ /List ::= [CONFIG_SSID, CONFIG_PASSWORD, CONFIG_BROADCAST, CONFIG_CHANNEL]

service_/WifiServiceClient? ::= (WifiServiceClient --no-open).open

open --ssid/string --password/string -> net.Interface:
  service := service_
  if not service: throw "WiFi unavailable"
  values ::= [ssid, password]
  return SystemInterface_ service (service.connect OPEN_KEYS_ values)

establish --ssid/string --password/string -> net.Interface
    --broadcast/bool=true
    --channel/int=1:
  service := service_
  if not service: throw "WiFi unavailable"
  values := [ssid, password, broadcast, channel]
  return SystemInterface_ service (service.establish ESTABLISH_KEYS_ values)
