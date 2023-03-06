// Copyright (C) 2022 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import net
import monitor
import log

import net.modules.dns as dns_module
import net.wifi

import encoding.tison
import system.assets
import system.firmware
import system.storage

import system.api.wifi show WifiService
import system.api.network show NetworkService
import system.services show ServiceResource
import system.base.network show NetworkModule NetworkResource NetworkState

import ..shared.network_base

// Keep in sync with the definitions in WifiResourceGroup.
OWN_ADDRESS_INDEX_        ::= 0
MAIN_DNS_ADDRESS_INDEX_   ::= 1
BACKUP_DNS_ADDRESS_INDEX_ ::= 2

// Use lazy initialization to delay opening the storage bucket
// until we need it the first time. From that point forward,
// we keep it around forever.
bucket_/storage.Bucket ::= storage.Bucket.open --flash "toitlang.org/wifi"

class WifiServiceProvider extends NetworkServiceProviderBase:
  static WIFI_CONFIG_STORE_KEY ::= "system/wifi"
  state_/NetworkState ::= NetworkState

  constructor:
    super "system/wifi/esp32" --major=0 --minor=1
    provides WifiService.SELECTOR --handler=this

  handle pid/int client/int index/int arguments/any -> any:
    if index == WifiService.CONNECT_INDEX:
      return connect client arguments
    if index == WifiService.ESTABLISH_INDEX:
      return establish client arguments
    if index == WifiService.AP_INFO_INDEX:
      network := (resource client arguments) as NetworkResource
      return ap_info network
    if index == WifiService.SCAN_INDEX:
      return scan arguments
    if index == WifiService.CONFIGURE_INDEX:
      return configure arguments
    return super pid client index arguments

  connect client/int -> List:
    return connect client null

  connect client/int config/Map? -> List:
    effective := config
    if not effective:
      catch --trace: effective = bucket_.get WIFI_CONFIG_STORE_KEY
      if not effective:
        effective = firmware.config["wifi"]
      if not effective:
        effective = {:}
        // If we move the WiFi service out of the system process,
        // the asset might simply be known as "config". For now,
        // it co-exists with other system assets.
        assets.decode.get "wifi" --if_present=: | encoded |
          catch --trace: effective = tison.decode encoded

    ssid/string? := effective.get wifi.CONFIG_SSID
    if not ssid or ssid.is_empty: throw "wifi ssid not provided"
    password/string := effective.get wifi.CONFIG_PASSWORD --if_absent=: ""

    module ::= (state_.up: WifiModule.sta this ssid password) as WifiModule
    try:
      if module.ap:
        throw "wifi already established in AP mode"
      if module.ssid != ssid or module.password != password:
        throw "wifi already connected with different credentials"

      resource := NetworkResource this client state_ --notifiable
      return [resource.serialize_for_rpc, NetworkService.PROXY_ADDRESS | NetworkService.PROXY_RESOLVE]
    finally: | is_exception exception |
      // If we're not returning a network resource to the client, we
      // must take care to decrement the usage count correctly.
      if is_exception: state_.down

  establish client/int config/Map? -> List:
    if not config: config = {:}

    ssid/string? := config.get wifi.CONFIG_SSID
    if not ssid or ssid.is_empty: throw "wifi ssid not provided"
    password/string := config.get wifi.CONFIG_PASSWORD --if_absent=: ""
    if password.size != 0 and password.size < 8:
      throw "wifi password must be at least 8 characters"
    channel/int := config.get wifi.CONFIG_CHANNEL --if_absent=: 1
    if channel < 1 or channel > 13:
      throw "wifi channel must be between 1 and 13"
    broadcast/bool := config.get wifi.CONFIG_BROADCAST --if_absent=: true

    module ::= (state_.up: WifiModule.ap this ssid password broadcast channel) as WifiModule
    try:
      if not module.ap:
        throw "wifi already connected in STA mode"
      if module.ssid != ssid or module.password != password:
        throw "wifi already established with different credentials"
      if module.channel != channel:
        throw "wifi already established on channel $module.channel"
      if module.broadcast != broadcast:
        no := broadcast ? "no " : ""
        throw "wifi already established with $(no)ssid broadcasting"
      resource := NetworkResource this client state_ --notifiable
      return [resource.serialize_for_rpc, NetworkService.PROXY_ADDRESS | NetworkService.PROXY_RESOLVE]
    finally: | is_exception exception |
      // If we're not returning a network resource to the client, we
      // must take care to decrement the usage count correctly.
      if is_exception: state_.down

  address resource/NetworkResource -> ByteArray:
    return (state_.module as WifiModule).address.to_byte_array

  resolve resource/ServiceResource host/string -> List:
    return [(dns_module.dns_lookup host).raw]

  ap_info resource/NetworkResource -> List:
    return (state_.module as WifiModule).ap_info

  scan config/Map -> List:
    if state_.module:
      throw "wifi already connected or established"
    module := WifiModule.sta this "" ""
    try:
      channels := config.get wifi.CONFIG_SCAN_CHANNELS
      passive := config.get wifi.CONFIG_SCAN_PASSIVE
      period := config.get wifi.CONFIG_SCAN_PERIOD
      return module.scan channels passive period
    finally:
      module.disconnect

  configure config/Map? -> none:
    if config:
      bucket_[WIFI_CONFIG_STORE_KEY] = config
    else:
      bucket_.remove WIFI_CONFIG_STORE_KEY

  on_module_closed module/WifiModule -> none:
    resources_do: it.notify_ NetworkService.NOTIFY_CLOSED

class WifiModule implements NetworkModule:
  static WIFI_CONNECTED    ::= 1 << 0
  static WIFI_IP_ASSIGNED  ::= 1 << 1
  static WIFI_IP_LOST      ::= 1 << 2
  static WIFI_DISCONNECTED ::= 1 << 3
  static WIFI_RETRY        ::= 1 << 4
  static WIFI_SCAN_DONE    ::= 1 << 5

  static WIFI_RETRY_DELAY_     ::= Duration --s=1
  static WIFI_CONNECT_TIMEOUT_ ::= Duration --s=10
  static WIFI_DHCP_TIMEOUT_    ::= Duration --s=16

  logger_/log.Logger ::= log.default.with_name "wifi"
  service/WifiServiceProvider

  // TODO(kasper): Consider splitting the AP and non-AP case out
  // into two subclasses.
  ap/bool
  ssid/string
  password/string
  broadcast/bool? := null
  channel/int? := null

  resource_group_ := ?
  wifi_events_/monitor.ResourceState_? := null
  ip_events_/monitor.ResourceState_? := null
  address_/net.IpAddress? := null

  constructor.sta .service .ssid .password:
    resource_group_ = wifi_init_ false
    ap = false

  constructor.ap .service .ssid .password .broadcast .channel:
    resource_group_ = wifi_init_ true
    ap = true

  address -> net.IpAddress:
    return address_

  connect -> none:
    with_timeout WIFI_CONNECT_TIMEOUT_: wait_for_connected_
    if ap:
      wait_for_static_ip_address_
    else:
      with_timeout WIFI_DHCP_TIMEOUT_: wait_for_dhcp_ip_address_

  disconnect -> none:
    if not resource_group_:
      return

    if wifi_events_:
      wifi_events_.dispose
      wifi_events_ = null
    if ip_events_:
      ip_events_.dispose
      ip_events_ = null

    logger_.debug "closing"
    wifi_close_ resource_group_
    resource_group_ = null
    address_ = null
    service.on_module_closed this

  wait_for_connected_:
    try:
      logger_.debug "connecting"
      while true:
        resource ::= ap
            ? wifi_establish_ resource_group_ ssid password broadcast channel
            : wifi_connect_ resource_group_ ssid password
        wifi_events_ = monitor.ResourceState_ resource_group_ resource
        state := wifi_events_.wait
        if (state & WIFI_CONNECTED) != 0:
          wifi_events_.clear_state WIFI_CONNECTED
          logger_.debug "connected"
          wifi_events_.set_callback:: on_event_ it
          return
        else if (state & WIFI_RETRY) != 0:
          // We will be creating a new ResourceState object on the next
          // iteration, so we need to dispose the one from this attempt.
          wifi_events_.dispose
          wifi_events_ = null
          reason ::= wifi_disconnect_reason_ resource
          logger_.info "retrying" --tags={"reason": reason}
          wifi_disconnect_ resource_group_ resource
          sleep WIFI_RETRY_DELAY_
          continue
        else if (state & WIFI_DISCONNECTED) != 0:
          reason ::= wifi_disconnect_reason_ resource
          logger_.warn "connect failed" --tags={"reason": reason}
          throw "CONNECT_FAILED: $reason"
    finally: | is_exception exception |
      if is_exception and exception.value == DEADLINE_EXCEEDED_ERROR:
        logger_.warn "connect failed" --tags={"reason": "timeout"}

  wait_for_dhcp_ip_address_ -> none:
    resource := wifi_setup_ip_ resource_group_
    ip_events_ = monitor.ResourceState_ resource_group_ resource
    state := ip_events_.wait
    if (state & WIFI_IP_ASSIGNED) == 0: throw "IP_ASSIGN_FAILED"
    ip_events_.clear_state WIFI_IP_ASSIGNED
    ip ::= (wifi_get_ip_ resource_group_ OWN_ADDRESS_INDEX_) or #[0, 0, 0, 0]
    address_ = net.IpAddress ip
    logger_.info "network address dynamically assigned through dhcp" --tags={"ip": address_}
    configure_dns_ --from_dhcp
    ip_events_.set_callback:: on_event_ it

  wait_for_static_ip_address_ -> none:
    ip ::= (wifi_get_ip_ resource_group_ OWN_ADDRESS_INDEX_) or #[0, 0, 0, 0]
    address_ = net.IpAddress ip
    logger_.info "network address statically assigned" --tags={"ip": address_}
    configure_dns_ --from_dhcp=false

  configure_dns_ --from_dhcp/bool -> none:
    main_dns := wifi_get_ip_ resource_group_ MAIN_DNS_ADDRESS_INDEX_
    backup_dns := wifi_get_ip_ resource_group_ BACKUP_DNS_ADDRESS_INDEX_
    dns_ips := []
    if main_dns: dns_ips.add (net.IpAddress main_dns)
    if backup_dns: dns_ips.add (net.IpAddress backup_dns)
    if dns_ips.size != 0:
      dns_module.dhcp_client_ = dns_module.DnsClient dns_ips
      if from_dhcp:
        logger_.info "dns server address dynamically assigned through dhcp" --tags={"ip": dns_ips}
      else:
        logger_.info "dns server address statically assigned" --tags={"ip": dns_ips}
    else:
      dns_module.dhcp_client_ = null
      logger_.info "dns server address not supplied by network; using fallback dns servers"

  ap_info -> List:
    return wifi_get_ap_info_ resource_group_

  scan channels/ByteArray passive/bool period/int -> List:
    if ap or not resource_group_:
      throw "wifi is AP mode or not initialized"

    resource := wifi_init_scan_ resource_group_
    scan_events := monitor.ResourceState_ resource_group_ resource
    result := []
    try:
      channels.do:
        wifi_start_scan_ resource_group_ it passive period
        state := scan_events.wait
        if (state & WIFI_SCAN_DONE) == 0: throw "WIFI_SCAN_ERROR"
        scan_events.clear_state WIFI_SCAN_DONE
        array := wifi_read_scan_ resource_group_
        result.add_all array
    finally:
      scan_events.dispose

    return result

  on_event_ state/int:
    // TODO(kasper): We should be clearing the state in the
    // $monitor.ResourceState_ object, but since we're only
    // closing here it doesn't really matter. Room for
    // improvement though.
    if (state & (WIFI_DISCONNECTED | WIFI_IP_LOST)) != 0: disconnect

// ----------------------------------------------------------------------------

wifi_init_ ap:
  #primitive.wifi.init

wifi_close_ resource_group:
  #primitive.wifi.close

wifi_connect_ resource_group ssid password:
  #primitive.wifi.connect

wifi_establish_ resource_group ssid password broadcast channel:
  #primitive.wifi.establish

wifi_setup_ip_ resource_group:
  #primitive.wifi.setup_ip

wifi_disconnect_ resource_group resource:
  #primitive.wifi.disconnect

wifi_disconnect_reason_ resource:
  #primitive.wifi.disconnect_reason

wifi_get_ip_ resource_group index/int -> ByteArray?:
  #primitive.wifi.get_ip

wifi_init_scan_ resource_group:
  #primitive.wifi.init_scan

wifi_start_scan_ resource_group channel passive period_ms:
  #primitive.wifi.start_scan

wifi_read_scan_ resource_group -> Array_:
  #primitive.wifi.read_scan

wifi_get_ap_info_ resource_group -> Array_:
  #primitive.wifi.ap_info
