// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import system.api.wifi show WifiServiceClient

import .impl

CONFIG_SSID      /string ::= "wifi.ssid"
CONFIG_PASSWORD  /string ::= "wifi.password"

CONFIG_BROADCAST /string ::= "wifi.broadcast"
CONFIG_CHANNEL   /string ::= "wifi.channel"

CONFIG_SCAN_CHANNEL /string ::= "scan.channel"
CONFIG_SCAN_PASSIVE /string ::= "scan.passive"
CONFIG_SCAN_PERIOD  /string ::= "scan.period"

SCAN_AP_SSID     /string ::= "scan.ap.ssid"
SCAN_AP_BSSID    /string ::= "scan.ap.bssid"
SCAN_AP_RSSI     /string ::= "scan.ap.rssi"
SCAN_AP_AUTHMODE /string ::= "scan.ap.authmode"
SCAN_AP_CHANNEL  /string ::= "scan.ap.channel"

SCAN_TIMEOUT_/int := 1000 /* microseconds */ 

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

scan channels/ByteArray --passive/bool=false --period_per_channel/int=SCAN_TIMEOUT_ -> List?:
  if channels.size < 1: throw "Channels are unspecified"
  ap_list := List
  channels.do:
    channel/int := it
    data := scan
        --channel=channel
        --passive=passive
        --period=period_per_channel
    if data != null:
      ap_list += data
  return ap_list.size > 0 ? ap_list : null

scan --channel/int=1 --passive/bool=false --period/int=SCAN_TIMEOUT_ -> List?:
  service := service_
  if not service: throw "WiFi unavailable"
  config ::= {
    CONFIG_SCAN_PASSIVE: passive,
    CONFIG_SCAN_CHANNEL: channel,
    CONFIG_SCAN_PERIOD: period,
  }
  return service.scan config

wifi_authmode_name number/int -> string:
  WIFI_AUTHMODE_NAME /Map ::= {
    0: "Open",
    1: "WEP",
    2: "WPA PSK",
    3: "WPA2 PSK",
    4: "WPA/WPA2 PSK",
    5: "WPA2 Enterprise",
    6: "WPA3 PSK",
    7: "WPA2/WPA3 PSK",
    8: "WAPI PSK",
  }

  if number < 0 or number >= WIFI_AUTHMODE_NAME.size:
    return "Undefined"
  return WIFI_AUTHMODE_NAME[number]

class WifiInterface_ extends SystemInterface_ implements Interface:
  constructor client/WifiServiceClient connection/List:
    super client connection

  signal_strength -> float:
    rssi := (client_ as WifiServiceClient).rssi handle_
    if not rssi: throw "wifi not connected in STA mode"
    // RSSI is usually in the range [-100..-35].
    rssi = min 65 (max 0 rssi + 100)
    return rssi / 65.0
