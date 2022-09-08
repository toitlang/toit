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

interface Interface extends net.Interface:
  /**
  Returns the signal strength of the current access point association
    as a float in the range [0..1].

  Throws an exception if this network isn't currently connected to an
    access point.
  */
  signal_strength -> float

open --ssid/string --password/string -> Interface
    --save/bool=false:
  return open --save=save {
    CONFIG_SSID: ssid,
    CONFIG_PASSWORD: password,
  }

open config/Map? -> Interface
    --save/bool=false:
  service := service_
  if not service: throw "WiFi unavailable"
  return WifiInterface_ service (service.connect config save)

establish --ssid/string --password/string -> net.Interface
    --broadcast/bool=true
    --channel/int=1:
  return establish {
    CONFIG_SSID: ssid,
    CONFIG_PASSWORD: password,
    CONFIG_BROADCAST: broadcast,
    CONFIG_CHANNEL: channel,
  }

establish config/Map? -> Interface:
  service := service_
  if not service: throw "WiFi unavailable"
  return WifiInterface_ service (service.establish config)

class WifiInterface_ extends SystemInterface_ implements Interface:
  constructor client/WifiServiceClient connection/List:
    super client connection

  signal_strength -> float:
    rssi := (client_ as WifiServiceClient).rssi handle_
    if not rssi: throw "wifi not connected in STA mode"
    // RSSI is usually in the range [-100..-35].
    rssi = min 65 (max 0 rssi + 100)
    return rssi / 65.0
