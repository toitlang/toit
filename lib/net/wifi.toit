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

CONFIG_SCAN_CHANNELS /string ::= "scan.channels"
CONFIG_SCAN_PASSIVE  /string ::= "scan.passive"
CONFIG_SCAN_PERIOD   /string ::= "scan.period"

SCAN_AP_SSID     /string ::= "scan.ap.ssid"
SCAN_AP_BSSID    /string ::= "scan.ap.bssid"
SCAN_AP_RSSI     /string ::= "scan.ap.rssi"
SCAN_AP_AUTHMODE /string ::= "scan.ap.authmode"
SCAN_AP_CHANNEL  /string ::= "scan.ap.channel"

WIFI_SCAN_SSID_     ::= 0
WIFI_SCAN_BSSID_    ::= 1
WIFI_SCAN_RSSI_     ::= 2
WIFI_SCAN_AUTHMODE_ ::= 3
WIFI_SCAN_CHANNEL_  ::= 4
WIFI_SCAN_ELEMENT_COUNT_ ::= 5

SCAN_TIMEOUT_MS_/int := 1000 /* microseconds */ 

service_/WifiServiceClient? ::= (WifiServiceClient --no-open).open

class AccessPoint:
  ssid/string := ?
  bssid/ByteArray := ?
  rssi/int := ?
  authmode/int := ?
  channel/int := ?

  static WIFI_AUTHMODE_NAME_/Map ::= {
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

  constructor .ssid/string .bssid/ByteArray .rssi/int .authmode/int .channel/int:

  authmode_name -> string:
    if authmode < 0 or authmode >= WIFI_AUTHMODE_NAME_.size:
      return "Undefined"
    return WIFI_AUTHMODE_NAME_[authmode]
  
  bssid_name -> string:
    return (List bssid.size: "$(%02x bssid[it])").join ":"

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

scan channels/ByteArray --passive/bool=false --period_per_channel_ms/int=SCAN_TIMEOUT_MS_ -> List?:
  if channels.size < 1: throw "Channels are unspecified"

  service := service_
  if not service: throw "WiFi unavailable"

  ap_list := List
  config ::= {
    CONFIG_SCAN_PASSIVE: passive,
    CONFIG_SCAN_CHANNELS: channels,
    CONFIG_SCAN_PERIOD: period_per_channel_ms,
  }

  ap_array := service.scan config
  ap_count := ap_array.size / WIFI_SCAN_ELEMENT_COUNT_
  ap_count.repeat:
    offset := it * WIFI_SCAN_ELEMENT_COUNT_
    ap := AccessPoint
        ap_array[offset + WIFI_SCAN_SSID_]
        ap_array[offset + WIFI_SCAN_BSSID_]
        ap_array[offset + WIFI_SCAN_RSSI_]
        ap_array[offset + WIFI_SCAN_AUTHMODE_]
        ap_array[offset + WIFI_SCAN_CHANNEL_]
    ap_list.add ap

  return ap_list.size > 0 ? ap_list : null

class WifiInterface_ extends SystemInterface_ implements Interface:
  constructor client/WifiServiceClient connection/List:
    super client connection

  signal_strength -> float:
    rssi := (client_ as WifiServiceClient).rssi handle_
    if not rssi: throw "wifi not connected in STA mode"
    // RSSI is usually in the range [-100..-35].
    rssi = min 65 (max 0 rssi + 100)
    return rssi / 65.0
