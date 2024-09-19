// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import system.api.wifi show WifiServiceClient

CONFIG-SSID      /string ::= "wifi.ssid"
CONFIG-PASSWORD  /string ::= "wifi.password"

CONFIG-BROADCAST /string ::= "wifi.broadcast"
CONFIG-CHANNEL   /string ::= "wifi.channel"

CONFIG-SCAN-CHANNELS /string ::= "scan.channels"
CONFIG-SCAN-PASSIVE  /string ::= "scan.passive"
CONFIG-SCAN-PERIOD   /string ::= "scan.period"

SCAN-AP-SSID     /string ::= "scan.ap.ssid"
SCAN-AP-BSSID    /string ::= "scan.ap.bssid"
SCAN-AP-RSSI     /string ::= "scan.ap.rssi"
SCAN-AP-AUTHMODE /string ::= "scan.ap.authmode"
SCAN-AP-CHANNEL  /string ::= "scan.ap.channel"

WIFI-SCAN-SSID_     ::= 0
WIFI-SCAN-BSSID_    ::= 1
WIFI-SCAN-RSSI_     ::= 2
WIFI-SCAN-AUTHMODE_ ::= 3
WIFI-SCAN-CHANNEL_  ::= 4
WIFI-SCAN-ELEMENT-COUNT_ ::= 5

SCAN-TIMEOUT-MS_/int := 1000

service_/WifiServiceClient? ::= (WifiServiceClient).open
    --if-absent=: null

class AccessPoint:
  ssid/string
  bssid/ByteArray
  rssi/int
  authmode/int
  channel/int

  static WIFI-AUTHMODE-NAME_/List ::= [
    "Open",
    "WEP",
    "WPA PSK",
    "WPA2 PSK",
    "WPA/WPA2 PSK",
    "WPA2 Enterprise",
    "WPA3 PSK",
    "WPA2/WPA3 PSK",
    "WAPI PSK",
  ]

  constructor --.ssid/string --.bssid/ByteArray --.rssi/int --.authmode/int --.channel/int:

  authmode-name -> string:
    if authmode < 0 or authmode >= WIFI-AUTHMODE-NAME_.size:
      return "Undefined"
    return WIFI-AUTHMODE-NAME_[authmode]

  bssid-name -> string:
    return (List bssid.size: "$(%02x bssid[it])").join ":"

class Client extends net.Client:
  constructor client/WifiServiceClient --name/string? connection/List:
    super client --name=name connection

  /**
  Returns information about the access point this $Client is currently
    connected to.

  Throws an exception if this network isn't currently connected to an
    access point.
  */
  access-point -> AccessPoint:
    info := (client_ as WifiServiceClient).ap-info handle_
    return AccessPoint
        --ssid=info[WIFI-SCAN-SSID_]
        --bssid=info[WIFI-SCAN-BSSID_]
        --rssi=info[WIFI-SCAN-RSSI_]
        --authmode=info[WIFI-SCAN-AUTHMODE_]
        --channel=info[WIFI-SCAN-CHANNEL_]

  /**
  Returns the signal strength of the current access point association
    as a float in the range [0..1].

  Throws an exception if this network isn't currently connected to an
    access point.
  */
  signal-strength -> float:
    info := (client_ as WifiServiceClient).ap-info handle_
    rssi := info[WIFI-SCAN-RSSI_]
    // RSSI is usually in the range [-100..-35].
    rssi = min 65 (max 0 rssi + 100)
    return rssi / 65.0

open --ssid/string --password/string -> Client
    --name/string?=null
    --save/bool=false:
  return open --name=name --save=save {
    CONFIG-SSID: ssid,
    CONFIG-PASSWORD: password,
  }

open config/Map? -> Client
    --name/string?=null
    --save/bool=false:
  service := service_
  if not service: throw "WiFi unavailable"
  connection := service.connect config
  if save: service.configure config
  return Client service --name=name connection

establish --ssid/string --password/string -> Client
    --name/string?=null
    --broadcast/bool=true
    --channel/int=1:
  return establish --name=name {
    CONFIG-SSID: ssid,
    CONFIG-PASSWORD: password,
    CONFIG-BROADCAST: broadcast,
    CONFIG-CHANNEL: channel,
  }

establish config/Map? -> Client
    --name/string?=null:
  service := service_
  if not service: throw "WiFi unavailable"
  return Client service --name=name (service.establish config)

scan channels/ByteArray --passive/bool=false --period-per-channel-ms/int=SCAN-TIMEOUT-MS_ -> List:
  if channels.size < 1: throw "Channels are unspecified"

  service := service_
  if not service: throw "WiFi unavailable"

  config ::= {
    CONFIG-SCAN-PASSIVE: passive,
    CONFIG-SCAN-CHANNELS: channels,
    CONFIG-SCAN-PERIOD: period-per-channel-ms,
  }

  data-list := service.scan config
  ap-count := data-list.size / WIFI-SCAN-ELEMENT-COUNT_
  return List ap-count:
    offset := it * WIFI-SCAN-ELEMENT-COUNT_
    AccessPoint
        --ssid=data-list[offset + WIFI-SCAN-SSID_]
        --bssid=data-list[offset + WIFI-SCAN-BSSID_]
        --rssi=data-list[offset + WIFI-SCAN-RSSI_]
        --authmode=data-list[offset + WIFI-SCAN-AUTHMODE_]
        --channel=data-list[offset + WIFI-SCAN-CHANNEL_]

/**
Configure the WiFi service to connect using the given $ssid and
  $password credentials by default.

The new defaults will take effect on the next call to $open that
  where no configuration is explicitly provided.

Use $(open --ssid --password --save) to configure the WiFi
  service only after verifying that connecting succeeds.
*/
configure --ssid/string --password/string -> none:
  configure {
    CONFIG-SSID: ssid,
    CONFIG-PASSWORD: password,
  }

/**
Configure the WiFi service's default way of connecting to
  an access point. The $config contains entries for the
  credentials such as ssid and password.

The new defaults will take effect on the next call to $open that
  where no configuration is explicitly provided.

Use $(configure --reset) to reset the stored configuration.
*/
configure config/Map -> none:
  service := service_
  if not service: throw "WiFi unavailable"
  service.configure config

/**
Reset the stored WiFi configuration and go back to using
  the WiFi credentials embedded in the firmware image.
*/
configure --reset/True -> none:
  service := service_
  if not service: throw "WiFi unavailable"
  service.configure null
