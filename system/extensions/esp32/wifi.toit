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

import net.modules.dns as dns-module
import net.modules.udp as udp-module
import net.udp
import net.wifi

import encoding.tison
import system
import system.assets
import system.firmware
import system.storage

import system.api.wifi show WifiService
import system.api.network show NetworkService
import system.services show ServiceResource
import system.base.network show NetworkModule NetworkResource NetworkState

import ..shared.network-base

// Keep in sync with the definitions in WifiResourceGroup.
OWN-ADDRESS-INDEX_        ::= 0
MAIN-DNS-ADDRESS-INDEX_   ::= 1
BACKUP-DNS-ADDRESS-INDEX_ ::= 2

// Use lazy initialization to delay opening the storage bucket
// until we need it the first time. From that point forward,
// we keep it around forever.
bucket_/storage.Bucket ::= storage.Bucket.open --flash "toitlang.org/wifi"

class WifiServiceProvider extends NetworkServiceProviderBase implements udp.Interface:
  static WIFI-CONFIG-STORE-KEY ::= "system/wifi"
  state_/NetworkState ::= NetworkState

  constructor:
    super "system/wifi/esp32" --major=0 --minor=1
        --tags=[NetworkService.TAG-WIFI]
    provides WifiService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == WifiService.CONNECT-INDEX:
      return connect client arguments
    if index == WifiService.ESTABLISH-INDEX:
      return establish client arguments
    if index == WifiService.AP-INFO-INDEX:
      network := (resource client arguments) as NetworkResource
      return ap-info network
    if index == WifiService.SCAN-INDEX:
      return scan arguments
    if index == WifiService.CONFIGURE-INDEX:
      return configure arguments
    return super index arguments --gid=gid --client=client

  connect client/int -> List:
    return connect client null

  connect client/int config/Map? -> List:
    effective := config
    if not effective:
      catch --trace: effective = bucket_.get WIFI-CONFIG-STORE-KEY
      if not effective:
        effective = firmware.config["wifi"]
      if not effective:
        effective = {:}
        // If we move the WiFi service out of the system process,
        // the asset might simply be known as "config". For now,
        // it co-exists with other system assets.
        assets.decode.get "wifi" --if-present=: | encoded |
          catch --trace: effective = tison.decode encoded

    ssid/string? := effective.get wifi.CONFIG-SSID
    if not ssid or ssid.is-empty: throw "wifi ssid not provided"
    password/string := effective.get wifi.CONFIG-PASSWORD --if-absent=: ""

    module ::= (state_.up: WifiModule.sta this ssid password) as WifiModule
    try:
      if module.ap:
        throw "wifi already established in AP mode"
      if module.ssid != ssid or module.password != password:
        throw "wifi already connected with different credentials"

      resource := NetworkResource this client state_ --notifiable
      return [
        resource.serialize-for-rpc,
        NetworkService.PROXY-ADDRESS | NetworkService.PROXY-RESOLVE,
        "wifi:sta"
      ]
    finally: | is-exception exception |
      // If we're not returning a network resource to the client, we
      // must take care to decrement the usage count correctly.
      if is-exception:
        critical-do: state_.down

  establish client/int config/Map? -> List:
    if not config: config = {:}

    ssid/string? := config.get wifi.CONFIG-SSID
    if not ssid or ssid.is-empty: throw "wifi ssid not provided"
    password/string := config.get wifi.CONFIG-PASSWORD --if-absent=: ""
    if password.size != 0 and password.size < 8:
      throw "wifi password must be at least 8 characters"
    channel/int := config.get wifi.CONFIG-CHANNEL --if-absent=: 1
    // The safe world mode only allows channels 1-11.
    // Most of the world uses channels 1-13.
    // Japan allows channels 1-14. For simplicity we go with 1-13.
    if not 1 <= channel <= 13:
      throw "wifi channel must be between 1 and 13"
    broadcast/bool := config.get wifi.CONFIG-BROADCAST --if-absent=: true

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
      return [
        resource.serialize-for-rpc,
        NetworkService.PROXY-ADDRESS | NetworkService.PROXY-RESOLVE,
        "wifi:ap"
      ]
    finally: | is-exception exception |
      // If we're not returning a network resource to the client, we
      // must take care to decrement the usage count correctly.
      if is-exception:
        critical-do: state_.down

  address resource/NetworkResource -> ByteArray:
    return (state_.module as WifiModule).address.to-byte-array

  resolve resource/ServiceResource host/string -> List:
    return (dns-module.dns-lookup-multi host --network=this).map: it.raw

  ap-info resource/NetworkResource -> List:
    return (state_.module as WifiModule).ap-info

  scan config/Map -> List:
    channels := config.get wifi.CONFIG-SCAN-CHANNELS
    passive := config.get wifi.CONFIG-SCAN-PASSIVE
    period := config.get wifi.CONFIG-SCAN-PERIOD
    connected := state_.up --if-unconnected=:
      // If the network is unconnected, we bring up the network
      // module, but keep it unconnected. We scan while keeping
      // the state lock, so others can't interfere with us. They
      // will have to wait their turn to bring the network up.
      unconnected := WifiModule.sta this "" ""
      return unconnected.scan channels passive period --close
    try:
      // Scan using the connected network module.
      return (connected as WifiModule).scan channels passive period
    finally:
      state_.down

  configure config/Map? -> none:
    if config:
      bucket_[WIFI-CONFIG-STORE-KEY] = config
    else:
      bucket_.remove WIFI-CONFIG-STORE-KEY

  on-module-closed module/WifiModule -> none:
    critical-do:
      resources-do: | resource/NetworkResource |
        if not resource.is-closed:
          resource.notify_ NetworkService.NOTIFY-CLOSED --close

  // This method comes from the udp.Interface definition. It is necessary
  // to allow the DNS client to use the WiFi when sending out requests.
  udp-open --port/int?=null -> udp.Socket:
    return udp-module.Socket this "0.0.0.0" (port ? port : 0)

class WifiModule implements NetworkModule:
  static WIFI-CONNECTED    ::= 1 << 0
  static WIFI-IP-ASSIGNED  ::= 1 << 1
  static WIFI-IP-LOST      ::= 1 << 2
  static WIFI-DISCONNECTED ::= 1 << 3
  static WIFI-RETRY        ::= 1 << 4
  static WIFI-SCAN-DONE    ::= 1 << 5

  static WIFI-RETRY-DELAY_     ::= Duration --s=1
  static WIFI-CONNECT-TIMEOUT_ ::= Duration --s=24
  static WIFI-DHCP-TIMEOUT_    ::= Duration --s=16

  logger_/log.Logger ::= log.default.with-name "wifi"
  service/WifiServiceProvider

  // TODO(kasper): Consider splitting the AP and non-AP case out
  // into two subclasses.
  ap/bool
  ssid/string
  password/string
  broadcast/bool? := null
  channel/int? := null

  resource-group_ := ?
  wifi-events_/monitor.ResourceState_? := null
  ip-events_/monitor.ResourceState_? := null
  address_/net.IpAddress? := null

  constructor.sta .service .ssid .password:
    resource-group_ = wifi-init_ false
    ap = false

  constructor.ap .service .ssid .password .broadcast .channel:
    resource-group_ = wifi-init_ true
    ap = true

  address -> net.IpAddress:
    return address_

  connect -> none:
    wifi-set-hostname_ resource-group_ system.hostname
    with-timeout WIFI-CONNECT-TIMEOUT_: wait-for-connected_
    if ap:
      wait-for-static-ip-address_
    else:
      with-timeout WIFI-DHCP-TIMEOUT_: wait-for-dhcp-ip-address_

  disconnect -> none:
    if not resource-group_:
      return

    // If we're disconnecting because of cancelation, we have
    // to make sure we still clean up. Logging and disposing
    // are (potentially) monitor operations, so we have to be
    // extra careful around those.
    critical-do:
      logger_.debug "closing"
      if wifi-events_:
        wifi-events_.dispose
        wifi-events_ = null
      if ip-events_:
        ip-events_.dispose
        ip-events_ = null

    wifi-close_ resource-group_
    resource-group_ = null
    address_ = null
    service.on-module-closed this

  wait-for-connected_:
    try:
      logger_.debug "connecting"
      while true:
        resource ::= ap
            ? wifi-establish_ resource-group_ ssid password broadcast channel
            : wifi-connect_ resource-group_ ssid password
        wifi-events_ = monitor.ResourceState_ resource-group_ resource
        state := wifi-events_.wait
        if (state & WIFI-CONNECTED) != 0:
          wifi-events_.clear-state WIFI-CONNECTED
          logger_.debug "connected"
          wifi-events_.set-callback:: on-event_ it
          return
        else if (state & WIFI-RETRY) != 0:
          // We will be creating a new ResourceState object on the next
          // iteration, so we need to dispose the one from this attempt.
          wifi-events_.dispose
          wifi-events_ = null
          reason ::= wifi-disconnect-reason_ resource
          logger_.info "retrying" --tags={"reason": reason}
          wifi-disconnect_ resource-group_ resource
          sleep WIFI-RETRY-DELAY_
          continue
        else if (state & WIFI-DISCONNECTED) != 0:
          reason ::= wifi-disconnect-reason_ resource
          logger_.warn "connect failed" --tags={"reason": reason}
          throw "CONNECT_FAILED: $reason"
    finally: | is-exception exception |
      if is-exception and exception.value == DEADLINE-EXCEEDED-ERROR:
        logger_.warn "connect failed" --tags={"reason": "timeout"}

  wait-for-dhcp-ip-address_ -> none:
    resource := wifi-setup-ip_ resource-group_
    ip-events_ = monitor.ResourceState_ resource-group_ resource
    state := ip-events_.wait
    if (state & WIFI-IP-ASSIGNED) == 0: throw "IP_ASSIGN_FAILED"
    ip-events_.clear-state WIFI-IP-ASSIGNED
    ip ::= (wifi-get-ip_ resource-group_ OWN-ADDRESS-INDEX_) or #[0, 0, 0, 0]
    address_ = net.IpAddress ip
    logger_.info "network address dynamically assigned through dhcp" --tags={"ip": address_}
    configure-dns_ --from-dhcp
    ip-events_.set-callback:: on-event_ it

  wait-for-static-ip-address_ -> none:
    ip ::= (wifi-get-ip_ resource-group_ OWN-ADDRESS-INDEX_) or #[0, 0, 0, 0]
    address_ = net.IpAddress ip
    logger_.info "network address statically assigned" --tags={"ip": address_}
    configure-dns_ --from-dhcp=false

  configure-dns_ --from-dhcp/bool -> none:
    main-dns := wifi-get-ip_ resource-group_ MAIN-DNS-ADDRESS-INDEX_
    backup-dns := wifi-get-ip_ resource-group_ BACKUP-DNS-ADDRESS-INDEX_
    dns-ips := []
    if main-dns: dns-ips.add (net.IpAddress main-dns)
    if backup-dns: dns-ips.add (net.IpAddress backup-dns)
    if dns-ips.size != 0:
      dns-module.dhcp-client_ = dns-module.DnsClient dns-ips
      if from-dhcp:
        logger_.info "dns server address dynamically assigned through dhcp" --tags={"ip": dns-ips}
      else:
        logger_.info "dns server address statically assigned" --tags={"ip": dns-ips}
    else:
      dns-module.dhcp-client_ = null
      logger_.info "dns server address not supplied by network; using fallback dns servers"

  ap-info -> List:
    return wifi-get-ap-info_ resource-group_

  scan channels/ByteArray passive/bool period/int --close/bool=false -> List:
    if ap or not resource-group_:
      throw "wifi is AP mode or not initialized"

    resource := wifi-init-scan_ resource-group_
    scan-events := monitor.ResourceState_ resource-group_ resource
    try:
      result := []
      channels.do:
        wifi-start-scan_ resource-group_ it passive period
        state := scan-events.wait
        if (state & WIFI-SCAN-DONE) == 0: throw "WIFI_SCAN_ERROR"
        scan-events.clear-state WIFI-SCAN-DONE
        array := wifi-read-scan_ resource-group_
        result.add-all array
      return result
    finally:
      scan-events.dispose
      if close:
        wifi-close_ resource-group_
        resource-group_ = null

  on-event_ state/int:
    // TODO(kasper): We should be clearing the state in the
    // $monitor.ResourceState_ object, but since we're only
    // closing here it doesn't really matter. Room for
    // improvement though.
    if (state & (WIFI-DISCONNECTED | WIFI-IP-LOST)) != 0: disconnect

// ----------------------------------------------------------------------------

wifi-init_ ap:
  #primitive.wifi.init

wifi-set-hostname_ resource-group hostname:
  #primitive.wifi.set-hostname

wifi-close_ resource-group:
  #primitive.wifi.close

wifi-connect_ resource-group ssid password:
  #primitive.wifi.connect

wifi-establish_ resource-group ssid password broadcast channel:
  #primitive.wifi.establish

wifi-setup-ip_ resource-group:
  #primitive.wifi.setup-ip

wifi-disconnect_ resource-group resource:
  #primitive.wifi.disconnect

wifi-disconnect-reason_ resource:
  #primitive.wifi.disconnect-reason

wifi-get-ip_ resource-group index/int -> ByteArray?:
  #primitive.wifi.get-ip

wifi-init-scan_ resource-group:
  #primitive.wifi.init-scan

wifi-start-scan_ resource-group channel passive period-ms:
  #primitive.wifi.start-scan

wifi-read-scan_ resource-group -> Array_:
  #primitive.wifi.read-scan

wifi-get-ap-info_ resource-group -> Array_:
  #primitive.wifi.ap-info
