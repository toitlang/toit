// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import log
import monitor
import net

TOIT_WIFI_CONNECTED_    ::= 1 << 0
TOIT_WIFI_DHCP_SUCCESS_ ::= 1 << 1
TOIT_WIFI_DISCONNECTED_ ::= 1 << 2
TOIT_WIFI_RETRY_        ::= 1 << 3

class Wifi:
  logger_/log.Logger ::= log.default.with_name "wifi"

  resource_group_ := wifi_init_

  ssid_ := null
  password_ := null

  address_/net.IpAddress? := null

  set_ssid ssid password:
    ssid_ = ssid
    password_ = password

  close:
    if resource_group_:
      wifi_close_ resource_group_
      resource_group_ = null

  address -> net.IpAddress:
    return address_

  connect:
    try:
      logger_.debug "connecting"
      while true:
        resource := wifi_connect_ resource_group_ ssid_ password_
        res := monitor.ResourceState_ resource_group_ resource
        state := res.wait
        res.dispose
        if (state & TOIT_WIFI_CONNECTED_) != 0:
          logger_.debug "connected"
          return
        else if (state & TOIT_WIFI_RETRY_) != 0:
          reason ::= wifi_disconnect_reason_ resource
          logger_.info "retrying" --tags={"reason": reason}
          wifi_disconnect_ resource_group_ resource
          // Retry with 1s delay.
          sleep --ms=1000
          continue
        else if (state & TOIT_WIFI_DISCONNECTED_) != 0:
          reason ::= wifi_disconnect_reason_ resource
          logger_.warn "connect failed" --tags={"reason": reason}
          close
          throw "CONNECT_FAILED: $reason"
    finally: | is_exception exception |
      if is_exception and exception.value == DEADLINE_EXCEEDED_ERROR:
        logger_.warn "connect failed" --tags={"reason": "timeout"}

  get_ip:
    resource := wifi_setup_ip_ resource_group_
    res := monitor.ResourceState_ resource_group_ resource
    state := res.wait
    res.dispose
    if (state & TOIT_WIFI_DHCP_SUCCESS_) != 0:
      ip := wifi_get_ip_ resource
      address_ = net.IpAddress.parse ip
      logger_.info "got ip" --tags={"ip": ip}
      return ip
    close
    throw "IP_ASSIGN_FAILED"

  rssi -> int?:
    return wifi_get_rssi_ resource_group_

wifi_init_:
  #primitive.wifi.init

wifi_close_ resource_group:
  #primitive.wifi.close

wifi_connect_ resource_group ssid password :
  #primitive.wifi.connect

wifi_setup_ip_ resource_group:
  #primitive.wifi.setup_ip

wifi_disconnect_ resource_group resource:
  #primitive.wifi.disconnect

wifi_disconnect_reason_ resource:
  #primitive.wifi.disconnect_reason

wifi_get_ip_ resource:
  #primitive.wifi.get_ip

wifi_get_rssi_ resource_group:
  #primitive.wifi.get_rssi

// TODO(anders): This should be moved to network-related endpoints.
wait_for_dhcp_:
  #primitive.dhcp.wait_for_lwip_dhcp_on_linux
