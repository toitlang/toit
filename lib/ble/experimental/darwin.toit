// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor show ResourceState_

/**
CoreBluetooth on macOS, as the Toit runtime exposes it: the primitives of
  `src/resources/ble_darwin.mm` and their event bits, wrapped in
  $Resource. `service.darwin-provider` builds the BLE provider on it.

Peers are CoreBluetooth identifiers (UUIDs), never addresses; an operation
  starts with a primitive call and completes with an event on the resource,
  which $Resource.wait collects. This runs on macOS only: on any other
  platform the primitives are absent (PRIMITIVE_LOOKUP_FAILED).
*/

// Event bits, as ble_host.h numbers them.
MALLOC-FAILED ::= 1 << 22
STARTED ::= 1 << 0
COMPLETED ::= 1 << 1
DISCOVERY ::= 1 << 2
DISCOVERY-OPERATION-FAILED ::= 1 << 21
CONNECTED ::= 1 << 3
CONNECT-FAILED ::= 1 << 4
DISCONNECTED ::= 1 << 5
SERVICES-DISCOVERED ::= 1 << 6
CHARACTERISTICS-DISCOVERED ::= 1 << 7
DESCRIPTORS-DISCOVERED ::= 1 << 8
VALUE-DATA-READY ::= 1 << 9
VALUE-DATA-READ-FAILED ::= 1 << 10
VALUE-WRITE-SUCCEEDED ::= 1 << 11
VALUE-WRITE-FAILED ::= 1 << 12
READY-TO-SEND-WITHOUT-RESPONSE ::= 1 << 13
SUBSCRIPTION-OPERATION-SUCCEEDED ::= 1 << 14
SUBSCRIPTION-OPERATION-FAILED ::= 1 << 15
ADVERTISE-START-SUCCEEDED ::= 1 << 16
ADVERTISE-START-FAILED ::= 1 << 17
SERVICE-ADD-SUCCEEDED ::= 1 << 18
SERVICE-ADD-FAILED ::= 1 << 19
DATA-RECEIVED ::= 1 << 20

/** Whether this runtime has the CoreBluetooth primitives. */
available -> bool:
  catch --unwind=(: it != "PRIMITIVE_LOOKUP_FAILED"):
    group_
    return true
  return false

group_ -> any:
  if not group__: group__ = init_
  return group__

group__ := null

/**
A native CoreBluetooth object with the events it raises.

$wait blocks until one of the given event bits is set and returns the
  state; a malloc failure reports itself as an error. $clear resets bits
  before starting an operation whose completion they signal.
*/
class Resource:
  handle/any? := null
  state_/ResourceState_? := null

  constructor .handle:
    state_ = ResourceState_ group_ handle

  is-closed -> bool: return handle == null

  wait bits/int -> int:
    check_
    state := state_.wait-for-state bits | MALLOC-FAILED
    if state & MALLOC-FAILED == 0: return state
    state_.clear-state MALLOC-FAILED
    throw-error --oom
    unreachable

  clear bits/int -> none:
    check_
    state_.clear-state bits

  /** Throws the error the native side recorded for this resource. */
  throw-error --oom/bool=false -> none:
    try:
      get-error_ handle oom
    finally:
      clear-error_ handle oom

  close -> none:
    if not handle: return
    resource := handle
    handle = null
    state_.dispose
    release-resource_ resource

  check_ -> none:
    if not handle: throw "BLE_CLOSED"

/** The adapter, opened once per process, with its central manager. */
class Adapter:
  adapter/Resource
  central/Resource

  constructor:
    adapter = Resource (create-adapter_ group_)
    adapter.wait STARTED
    central = Resource (create-central-manager_ adapter.handle)
    central.wait STARTED

  /** Opens the peripheral manager, once. */
  peripheral-manager -> Resource:
    if not peripheral_:
      peripheral_ = Resource (create-peripheral-manager_ adapter.handle false false)
      peripheral_.wait STARTED
    return peripheral_

  peripheral_/Resource? := null

// Primitives.

init_:
  #primitive.ble.init

create-adapter_ group:
  #primitive.ble.create-adapter

create-central-manager_ adapter:
  #primitive.ble.create-central-manager

create-peripheral-manager_ adapter bonding/bool secure-connections/bool:
  #primitive.ble.create-peripheral-manager

release-resource_ resource:
  #primitive.ble.release-resource

/** Starts a scan; $duration-us -1 scans until $scan-stop. */
scan-start central passive/bool duration-us/int interval/int window/int limited/bool:
  #primitive.ble.scan-start

/**
Returns the next discovered peripheral as [identifier string, rssi, name or
  null, service UUID strings or null, manufacturer data or null, flags,
  connectable], or null when none waits.
*/
scan-next central:
  #primitive.ble.scan-next

scan-stop central:
  #primitive.ble.scan-stop

/** Connects to the peripheral with the $identifier string; the device resource completes with CONNECTED. */
connect central identifier/string secure/bool:
  #primitive.ble.connect

disconnect device:
  #primitive.ble.disconnect

/** Discovers services (all with an empty array); the device completes with SERVICES-DISCOVERED. */
discover-services device uuids:
  #primitive.ble.discover-services

/** Returns [[uuid string, service resource]] after discovery. */
discover-services-result device:
  #primitive.ble.discover-services-result

discover-characteristics service uuids:
  #primitive.ble.discover-characteristics

/** Returns [[uuid string, properties, characteristic resource]] after discovery. */
discover-characteristics-result service:
  #primitive.ble.discover-characteristics-result

request-read characteristic:
  #primitive.ble.request-read

/** The last value received (a read result or a notification), or null. */
get-value characteristic:
  #primitive.ble.get-value

/**
Writes; returns 0 when done, 1 when VALUE-WRITE-* follows, 2 when the
  device must first signal READY-TO-SEND-WITHOUT-RESPONSE.
*/
write-value characteristic value/ByteArray with-response/bool allow-retry/bool:
  #primitive.ble.write-value

set-characteristic-notify characteristic enabled/bool:
  #primitive.ble.set-characteristic-notify

/** Advertises a name and service UUID strings; ADVERTISE-START-* follows. */
advertise-start peripheral-manager name/string services interval-us/int connection-mode/int flags/int:
  #primitive.ble.advertise-start

advertise-stop peripheral-manager:
  #primitive.ble.advertise-stop

add-service peripheral-manager uuid/string:
  #primitive.ble.add-service

add-characteristic service uuid/string properties/int permissions/int value/ByteArray?:
  #primitive.ble.add-characteristic

reserve-services peripheral-manager count/int:
  #primitive.ble.reserve-services

/** Publishes a service; SERVICE-ADD-* follows on the service resource. */
deploy-service service index/int:
  #primitive.ble.deploy-service

start-gatt-server peripheral-manager:
  #primitive.ble.start-gatt-server

set-value characteristic value/ByteArray:
  #primitive.ble.set-value

/** The subscribed centrals, as one opaque entry meaning "all of them". */
get-subscribed-clients characteristic:
  #primitive.ble.get-subscribed-clients

notify-characteristics-value characteristic client value/ByteArray:
  #primitive.ble.notify-characteristics-value

get-att-mtu resource:
  #primitive.ble.get-att-mtu

set-preferred-mtu adapter mtu/int:
  #primitive.ble.set-preferred-mtu

get-error_ resource oom/bool:
  #primitive.ble.get-error

clear-error_ resource oom/bool:
  #primitive.ble.clear-error
