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

service_/WifiServiceClient? ::= (WifiServiceClient --no-open).open

open --ssid/string --password/string -> net.Interface
    --save/bool=false:
  return open {
    CONFIG_SSID: ssid,
    CONFIG_PASSWORD: password,
  }

open config/Map? -> net.Interface
    --save/bool=false:
  service := service_
  if not service: throw "WiFi unavailable"
  return SystemInterface_ service (service.connect config save)

establish --ssid/string --password/string -> net.Interface
    --broadcast/bool=true
    --channel/int=1:
  return establish {
    CONFIG_SSID: ssid,
    CONFIG_PASSWORD: password,
    CONFIG_BROADCAST: broadcast,
    CONFIG_CHANNEL: channel,
  }

establish config/Map? -> net.Interface:
  service := service_
  if not service: throw "WiFi unavailable"
  return SystemInterface_ service (service.establish config)
