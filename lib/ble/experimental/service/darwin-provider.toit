// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import encoding.hex
import monitor
import ...advertisement show Advertisement DataBlock
import ...uuid show BleUuid
import ..darwin as darwin
import .api as api
import .link-operations as link-operations
import .provider as rpc

/**
The BLE provider on macOS, over CoreBluetooth (`ble.experimental.darwin`).

$Provider speaks the service protocol of `ble.v2` and the `ble` package
  with CoreBluetooth behind it instead of the Toit host and a controller.
  Peers are CoreBluetooth identifiers: 16 bytes with address type
  $PLATFORM-IDENTIFIER, never Bluetooth addresses. What macOS keeps to
  itself is reported as unsupported: PHY, connection parameters, transmit
  power, RSSI on a link, security (pairing happens on demand, driven by the
  OS), descriptors, included services, read handlers and write validation
  on a served database, the identity of connected centrals and their
  connect and disconnect events. Scan reports carry the fields macOS
  provides (name, service UUIDs, manufacturer data), re-encoded as
  advertising data.

Not verified on a Mac yet: written against the primitives the `ble`
  package used on macOS before it moved to `ble.v2`.
*/

/** The address type of a peer named by a platform identifier instead of an address. */
PLATFORM-IDENTIFIER ::= 4

/** How many centrals a served database may have at once, as far as macOS lets one know. */
UNKNOWN-PEER ::= ByteArray 16

class Provider extends rpc.Provider:
  adapter_/darwin.Adapter? := null
  published_/bool := false

  constructor --priority/int=services-priority_: super --priority=priority

  static services-priority_ ::= 0x80

  adapter -> darwin.Adapter:
    if not adapter_: adapter_ = darwin.Adapter
    return adapter_

  capabilities -> List:
    flags := api.CAP-SCAN | api.CAP-CONTINUOUS-SCAN | api.CAP-GATT-CENTRAL | api.CAP-GATT-PERIPHERAL |
        api.CAP-ADVERTISING | api.CAP-MIXED-ROLES
    return [flags, 60_000_000, 512, 517, 8]

  central-session-limit -> int: return 8
  peripheral-session-limit -> int: return 1
  mixed-role-sessions -> bool: return true

  /** macOS hides the adapter's address; no transmit power control, no 2M PHY control. */
  adapter-info -> List: return [ByteArray 6, false, null, false]

  create-session client/int -> rpc.Session:
    return PeripheralSession this client "Toit"

  create-builder client/int name/string -> rpc.Session:
    return PeripheralSession this client name

  create-scan client/int arguments/List -> rpc.Session:
    if arguments.size != 7: throw "INVALID_ARGUMENT"
    return ScanSession this client arguments

  create-connection client/int arguments/List -> rpc.Session:
    if arguments.size != 4: throw "INVALID_ARGUMENT"
    identifier/ByteArray := arguments[0]
    type/int := arguments[1]
    timeout/int := arguments[2]
    if identifier.size != 16 or type != PLATFORM-IDENTIFIER or not 1 <= timeout <= 60_000_000:
      throw "INVALID_ARGUMENT"
    return ConnectionSession this client identifier timeout

  create-advertising client/int arguments/List -> rpc.Session:
    if arguments.size != 4: throw "INVALID_ARGUMENT"
    return AdvertisingSession this client arguments[0]

// ---------------------------------------------------------------------------
// Identifiers and advertising data.

/** The 16 bytes of a CoreBluetooth identifier "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX". */
identifier-bytes text/string -> ByteArray:
  return hex.decode (text.replace --all "-" "")

/** The identifier string of its 16 bytes. */
identifier-string bytes/ByteArray -> string:
  text := (hex.encode bytes).to-ascii-upper
  return "$text[0..8]-$text[8..12]-$text[12..16]-$text[16..20]-$text[20..]"

uuid-string bytes/ByteArray -> string:
  return (BleUuid.from-reversed bytes).stringify

uuid-bytes text/string -> ByteArray:
  return (BleUuid text).to-byte-array --reversed

/** Encodes what macOS reports about an advertiser as advertising data. */
advertising-data name/string? services/List? manufacturer/ByteArray? -> ByteArray:
  uuids := services ? (services.map: | text/string | BleUuid text) : []
  advertisement := Advertisement --name=name --services=uuids --no-check-size
      --manufacturer-specific=(manufacturer and manufacturer.size >= 2 ? manufacturer : null)
  return advertisement.to-raw

/** The name and service UUID strings of advertising data, all macOS advertises. */
decode-advertising data/ByteArray -> List:
  advertisement := Advertisement.raw data
  return [advertisement.name or "", advertisement.services.map: | uuid/BleUuid | uuid.stringify]

// ---------------------------------------------------------------------------
// Scanning.

class ScanSession extends rpc.Session:
  provider_/Provider
  reports_/Queue_ ::= Queue_
  worker_/Task? := null
  ended_/monitor.Latch ::= monitor.Latch
  dropped_/int := 0

  constructor .provider_ client/int arguments/List:
    super provider_ client
    duration/int? := arguments[0]
    active/bool := arguments[1]
    filter/ByteArray? := arguments[5]
    limited/bool := arguments[6]
    wanted := filter ? (uuid-string filter) : null
    worker_ = task::
      central := provider_.adapter.central
      error := catch:
        central.clear darwin.COMPLETED
        darwin.scan-start central.handle (not active) (duration or -1) 0 0 limited
        try:
          while true:
            state := central.wait darwin.DISCOVERY | darwin.COMPLETED
            next := darwin.scan-next central.handle
            if not next:
              central.clear darwin.DISCOVERY
              if state & darwin.COMPLETED != 0: break
              continue
            services/List? := next[3]
            if wanted and (not services or not (services.any: (BleUuid it).stringify == wanted)):
              continue
            data := advertising-data next[2] services next[4]
            connectable/bool := next[6]
            reports_.add [connectable ? 0 : 3, PLATFORM-IDENTIFIER, identifier-bytes next[0], data, next[1]]
        finally:
          critical-do --no-respect-deadline:
            darwin.scan-stop central.handle
            catch: with-timeout --ms=1000: central.wait darwin.COMPLETED
      critical-do --no-respect-deadline:
        reports_.finish (error and error.stringify)
        ended_.set true

  is-released -> bool: return is-closed and ended_.has-value

  invoke index/int arguments/List -> any:
    if index == api.SCAN-NEXT: return reports_.take
    if index == api.SCAN-STOP:
      if worker_: worker_.cancel
      ended_.get
      return [0, reports_.dropped, reports_.remaining]
    return super index arguments

  on-closed -> none:
    super
    if worker_: worker_.cancel

/** Records or values in order, at most 32 waiting; fails takers when finished with an error. */
monitor Queue_:
  queue_/List := []
  done_/bool := false
  error_ := null
  dropped/int := 0

  add value -> none:
    if done_: return
    if queue_.size >= 32:
      dropped++
      return
    queue_.add value

  finish error -> none:
    done_ = true
    error_ = error

  remaining -> int: return queue_.size

  take -> any:
    await: done_ or not queue_.is-empty
    if error_: throw error_
    if not queue_.is-empty: return queue_.remove --at=0
    return null

// ---------------------------------------------------------------------------
// Central connections.

/** One entry of a session's handle table: what a synthetic handle names. */
class Entry_:
  kind/string  // "service", "declaration", "value", "cccd"
  resource/darwin.Resource?
  uuid/ByteArray
  properties/int

  constructor .kind .resource .uuid --.properties=0:

class ConnectionSession extends rpc.Session:
  provider_/Provider
  identifier_/ByteArray
  device_/darwin.Resource? := null
  handles_/List ::= []
  subscriptions_/Map ::= {:}
  next-subscription_/int := 0
  ready_/monitor.Latch ::= monitor.Latch
  ended_/monitor.Latch ::= monitor.Latch
  worker_/Task? := null

  constructor .provider_ client/int .identifier_ timeout/int:
    super provider_ client --value-limit=512
    worker_ = task:: run_ timeout

  is-central -> bool: return true
  is-released -> bool: return is-closed and ended_.has-value

  run_ timeout/int -> none:
    error := catch:
      device := darwin.Resource (darwin.connect provider_.adapter.central.handle (identifier-string identifier_) false)
      device_ = device
      state := with-timeout (Duration --us=timeout):
        device.wait darwin.CONNECTED | darwin.CONNECT-FAILED | darwin.DISCONNECTED
      if state & (darwin.CONNECT-FAILED | darwin.DISCONNECTED) != 0: throw "GATT_CONNECT_FAILED"
      ready_.set [identifier_.copy, PLATFORM-IDENTIFIER, darwin.get-att-mtu device.handle]
      device.wait darwin.DISCONNECTED
    critical-do --no-respect-deadline:
      if not ready_.has-value: ready_.set (error ? error.stringify : "GATT_CONNECTION_CLOSED") --exception
      subscriptions_.values.do: | subscription/Subscription_ | subscription.stop
      handles_.do: | entry/Entry_ | if entry.resource and entry.kind != "cccd": entry.resource.close
      if device_: device_.close
      ended_.set true

  on-closed -> none:
    super
    disconnect_

  disconnect_ -> none:
    device := device_
    if device and not device.is-closed:
      catch: darwin.disconnect device.handle
      catch: with-timeout --ms=3000: device.wait darwin.DISCONNECTED
    if worker_ and not ended_.has-value: worker_.cancel

  invoke index/int arguments/List -> any:
    if index == api.CENTRAL-STOP:
      disconnect_
      catch: with-timeout --ms=5000: ended_.get
      return null
    if index == api.CENTRAL-READY: return ready_.get
    ready_.get
    if link-operations.is-link-operation index:
      if index == api.LINK-INFO:
        return [0, 1, 1, 27, 27, 0, 0, 0, identifier_.copy, PLATFORM-IDENTIFIER, null, null]
      if index == api.WAIT-DISCONNECTED:
        ended_.get
        return 0x13
      throw "BLE_UNSUPPORTED"
    if index == api.SECURITY or index == api.REQUEST-SECURITY: return [true, [false, false, false]]
    error := catch --unwind=(: it is string):
      return [true, (operation_ index arguments)]
    if error is AttError_: return [false, error.request, error.handle, error.code]
    throw error.stringify

  operation_ index/int arguments/List -> any:
    if index == api.CENTRAL-REVISION: return 0
    if index == api.CENTRAL-CHECKED:
      if arguments.size != 3: throw "INVALID_ARGUMENT"
      return operation_ arguments[1] arguments[2]
    if index == api.CENTRAL-SERVICES:
      device := device_
      device.clear darwin.SERVICES-DISCOVERED | darwin.DISCOVERY-OPERATION-FAILED
      darwin.discover-services device.handle []
      wait-discovered_ device darwin.SERVICES-DISCOVERED
      result := []
      (darwin.discover-services-result device.handle).do: | found/List |
        uuid := uuid-bytes found[0]
        handle := register_ (Entry_ "service" (darwin.Resource found[1]) uuid)
        result.add [handle, handle, uuid]
      return result
    if index == api.CENTRAL-CHARACTERISTICS:
      if arguments.size != 2: throw "INVALID_ARGUMENT"
      service := entry_ arguments[0] "service"
      service.resource.clear darwin.CHARACTERISTICS-DISCOVERED | darwin.DISCOVERY-OPERATION-FAILED
      darwin.discover-characteristics service.resource.handle []
      wait-discovered_ service.resource darwin.CHARACTERISTICS-DISCOVERED
      result := []
      (darwin.discover-characteristics-result service.resource.handle).do: | found/List |
        uuid := uuid-bytes found[0]
        resource := darwin.Resource found[2]
        declaration := register_ (Entry_ "declaration" null uuid)
        handle := register_ (Entry_ "value" resource uuid --properties=found[1])
        cccd := register_ (Entry_ "cccd" resource uuid)
        result.add [declaration, handle, found[1], uuid, cccd]
      return result
    if index == api.CENTRAL-DESCRIPTORS or index == api.CENTRAL-INCLUDED: return []
    if index == api.CENTRAL-READ:
      if arguments.size != 1: throw "INVALID_ARGUMENT"
      return read_ (entry_ arguments[0] "value")
    if index == api.CENTRAL-WRITE or index == api.CENTRAL-WRITE-COMMAND:
      if arguments.size != 2: throw "INVALID_ARGUMENT"
      write_ (entry_ arguments[0] "value") arguments[1] --response=(index == api.CENTRAL-WRITE)
      return null
    if index == api.CENTRAL-READ-BY-UUID: throw (AttError_ 8 0 6)
    if index == api.CENTRAL-READ-MULTIPLE: throw (AttError_ 0x0e 0 6)
    if index == api.CENTRAL-MONITOR:
      // Service Changed is not surfaced by these primitives; the monitor is a no-op.
      token := ++next-subscription_
      subscriptions_[token] = Subscription_ null
      return token
    if index == api.CENTRAL-SUBSCRIBE:
      if arguments.size != 4: throw "INVALID_ARGUMENT"
      entry := entry_ arguments[0] "value"
      if subscriptions_.size >= 8: throw "ATT_SUBSCRIPTION_LIMIT"
      entry.resource.clear darwin.SUBSCRIPTION-OPERATION-FAILED | darwin.SUBSCRIPTION-OPERATION-SUCCEEDED
      darwin.set-characteristic-notify entry.resource.handle true
      state := entry.resource.wait darwin.SUBSCRIPTION-OPERATION-SUCCEEDED | darwin.SUBSCRIPTION-OPERATION-FAILED
      if state & darwin.SUBSCRIPTION-OPERATION-FAILED != 0: entry.resource.throw-error
      token := ++next-subscription_
      subscriptions_[token] = Subscription_ entry.resource
      return token
    if index == api.CENTRAL-SUBSCRIPTION-READY or index == api.CENTRAL-SUBSCRIPTION-NEXT or index == api.CENTRAL-UNSUBSCRIBE:
      if arguments.size != 1: throw "INVALID_ARGUMENT"
      subscription/Subscription_? := subscriptions_.get arguments[0]
      if not subscription: throw "ATT_SUBSCRIPTION_CLOSED"
      if index == api.CENTRAL-SUBSCRIPTION-READY: return null
      if index == api.CENTRAL-SUBSCRIPTION-NEXT: return subscription.values.take
      subscriptions_.remove arguments[0]
      subscription.stop
      return null
    throw "GATT_UNSUPPORTED_SERVICE_OPERATION"

  register_ entry/Entry_ -> int:
    handles_.add entry
    return handles_.size

  entry_ handle/int kind/string -> Entry_:
    if not 1 <= handle <= handles_.size: throw (AttError_ 0 handle 1)
    entry/Entry_ := handles_[handle - 1]
    if entry.kind != kind: throw (AttError_ 0 handle 1)
    return entry

  wait-discovered_ resource/darwin.Resource bit/int -> none:
    state := resource.wait bit | darwin.DISCONNECTED | darwin.DISCOVERY-OPERATION-FAILED
    if state & darwin.DISCONNECTED != 0: throw "GATT_CONNECTION_CLOSED"
    if state & darwin.DISCOVERY-OPERATION-FAILED != 0: resource.throw-error

  read_ entry/Entry_ -> ByteArray:
    resource := entry.resource
    resource.clear darwin.VALUE-DATA-READY | darwin.VALUE-DATA-READ-FAILED
    darwin.request-read resource.handle
    state := resource.wait darwin.VALUE-DATA-READY | darwin.VALUE-DATA-READ-FAILED | darwin.DISCONNECTED
    if state & darwin.DISCONNECTED != 0: throw "GATT_CONNECTION_CLOSED"
    if state & darwin.VALUE-DATA-READ-FAILED != 0: resource.throw-error
    return (darwin.get-value resource.handle) or #[]

  write_ entry/Entry_ value/ByteArray --response/bool -> none:
    resource := entry.resource
    while true:
      device_.clear darwin.READY-TO-SEND-WITHOUT-RESPONSE
      resource.clear darwin.VALUE-WRITE-FAILED | darwin.VALUE-WRITE-SUCCEEDED
      result := darwin.write-value resource.handle value response false
      if result == 0: return
      if result == 1:
        state := resource.wait darwin.VALUE-WRITE-FAILED | darwin.VALUE-WRITE-SUCCEEDED | darwin.DISCONNECTED
        if state & darwin.DISCONNECTED != 0: throw "GATT_CONNECTION_CLOSED"
        if state & darwin.VALUE-WRITE-FAILED != 0: resource.throw-error
        return
      // The peripheral cannot take another write without response yet.
      device_.wait darwin.READY-TO-SEND-WITHOUT-RESPONSE | darwin.DISCONNECTED

/** The peer refused; carried to the client as [false, request, handle, code]. */
class AttError_:
  request/int
  handle/int
  code/int
  constructor .request .handle .code:

/** Values of one subscription, collected by a task; a null resource is the Service Changed monitor. */
class Subscription_:
  values/Queue_ ::= Queue_
  worker_/Task? := null
  resource_/darwin.Resource?

  constructor .resource_:
    if resource_: start_ resource_

  start_ resource/darwin.Resource -> none:
    worker_ = task::
      error := catch:
        while true:
          resource.clear darwin.VALUE-DATA-READY
          value := darwin.get-value resource.handle
          if value:
            values.add value
            continue
          state := resource.wait darwin.VALUE-DATA-READY | darwin.DISCONNECTED
          if state & darwin.DISCONNECTED != 0: throw "GATT_CONNECTION_CLOSED"
      critical-do --no-respect-deadline: values.finish (error ? error.stringify : "ATT_SUBSCRIPTION_CLOSED")

  stop -> none:
    if worker_: worker_.cancel
    worker_ = null
    if resource_ and not resource_.is-closed: catch: darwin.set-characteristic-notify resource_.handle false
    values.finish "ATT_SUBSCRIPTION_CLOSED"

// ---------------------------------------------------------------------------
// The peripheral role: a database served once per process.

class PeripheralSession extends rpc.Session:
  provider_/Provider
  name_/string
  services_/List ::= []
  handles_/List ::= []
  values_/Map ::= {:}
  started_/bool := false
  peer_/monitor.Latch ::= monitor.Latch
  ended_/monitor.Latch ::= monitor.Latch
  watchers_/List ::= []
  current-service_/darwin.Resource? := null

  constructor .provider_ client/int .name_:
    super provider_ client --value-limit=512

  is-peripheral -> bool: return true
  is-released -> bool: return is-closed

  check-serving -> none:
    if not started_: throw "GATT_NOT_STARTED"

  check-building_ -> none:
    if started_: throw "GATT_DATABASE_SEALED"

  invoke index/int arguments/List -> any:
    if index == api.SET-HANDLER-TIMEOUT:
      check-building_
      return null
    if index == api.ADD-SERVICE:
      check-building_
      if arguments.size != 1 and arguments.size != 2: throw "INVALID_ARGUMENT"
      if provider_.published_: throw "BLE_UNSUPPORTED"
      uuid/ByteArray := arguments[0]
      service := darwin.Resource (darwin.add-service provider_.adapter.peripheral-manager.handle (uuid-string uuid))
      services_.add service
      current-service_ = service
      return register_ (Entry_ "service" service uuid)
    if index == api.ADD-CHARACTERISTIC:
      check-building_
      if arguments.size != 3: throw "INVALID_ARGUMENT"
      if not current-service_: throw "INVALID_ARGUMENT"
      uuid/ByteArray := arguments[0]
      flags/int := arguments[1]
      value/ByteArray := arguments[2]
      // The service flags: read 1, write 2, notify 4, indicate 128, write
      // command 256, encrypted 32; CoreBluetooth's bits are the standard ones.
      properties := (flags & 1 != 0 ? 0x02 : 0) | (flags & 256 != 0 ? 0x04 : 0) | (flags & 2 != 0 ? 0x08 : 0) |
          (flags & 4 != 0 ? 0x10 : 0) | (flags & 128 != 0 ? 0x20 : 0)
      encrypted := flags & 32 != 0
      permissions := (flags & 1 != 0 ? (encrypted ? 0x04 : 0x01) : 0) |
          (flags & (2 | 256) != 0 ? (encrypted ? 0x08 : 0x02) : 0)
      resource := darwin.Resource (darwin.add-characteristic current-service_.handle (uuid-string uuid) properties permissions value)
      register_ (Entry_ "declaration" null uuid)
      handle := register_ (Entry_ "value" resource uuid --properties=properties)
      values_[handle] = value.copy
      if flags & 4 != 0 or flags & 128 != 0: register_ (Entry_ "cccd" resource uuid)
      return handle
    if index == api.ADD-DESCRIPTOR or index == api.INCLUDE-SERVICE:
      throw "GATT_UNSUPPORTED_SERVICE_OPERATION"
    if index == api.START:
      check-building_
      if arguments.size != 2 and arguments.size != 3: throw "INVALID_ARGUMENT"
      start_ arguments[0]
      return null
    if index == api.PEER:
      check-serving
      return peer_.get
    if index == api.VALUE:
      if arguments.size != 1: throw "INVALID_ARGUMENT"
      return (values_.get arguments[0] --if-absent=: throw "GATT_INVALID_VALUE_HANDLE").copy
    if index == api.SET-VALUE:
      if arguments.size != 2: throw "INVALID_ARGUMENT"
      set-value_ arguments[0] arguments[1]
      return null
    if index == api.NOTIFY or index == api.INDICATE:
      check-serving
      if arguments.size != 1: throw "INVALID_ARGUMENT"
      entry := entry_ arguments[0]
      notify_ entry values_[arguments[0]]
      return index == api.NOTIFY ? true : 1
    if index == api.NOTIFY-VALUES:
      check-serving
      if arguments.size != 2: throw "INVALID_ARGUMENT"
      entry := entry_ arguments[0]
      values/List := arguments[1]
      values.do: | value/ByteArray |
        set-value_ arguments[0] value
        notify_ entry value
      return values.size
    if index == api.WAIT-INDICATION: return null
    if index == api.MTU:
      mtu := 23
      catch: mtu = darwin.get-att-mtu provider_.adapter.peripheral-manager.handle
      return mtu
    if index == api.PERIPHERAL-ADVERTISING-UPDATE:
      check-serving
      if arguments.size != 2: throw "INVALID_ARGUMENT"
      advertise_ arguments[0]
      return true
    if index == api.SECURITY or index == api.REQUEST-SECURITY: return [false, false, false]
    if link-operations.is-link-operation index:
      if index == api.LINK-INFO:
        return [1, 1, 1, 27, 27, 0, 0, 0, UNKNOWN-PEER.copy, PLATFORM-IDENTIFIER, null, null]
      if index == api.WAIT-DISCONNECTED:
        ended_.get
        return 0x16
      throw "BLE_UNSUPPORTED"
    return super index arguments

  register_ entry/Entry_ -> int:
    handles_.add entry
    return handles_.size

  entry_ handle/int -> Entry_:
    if not 1 <= handle <= handles_.size: throw "GATT_INVALID_VALUE_HANDLE"
    entry/Entry_ := handles_[handle - 1]
    if entry.kind != "value": throw "GATT_INVALID_VALUE_HANDLE"
    return entry

  set-value_ handle/int value/ByteArray -> none:
    entry := entry_ handle
    values_[handle] = value.copy
    darwin.set-value entry.resource.handle value

  notify_ entry/Entry_ value/ByteArray -> none:
    (darwin.get-subscribed-clients entry.resource.handle).do: | client |
      darwin.notify-characteristics-value entry.resource.handle client value

  /** Publishes the services and advertises; the one anonymous peer is connected from here on. */
  start_ advertisement/ByteArray -> none:
    manager := provider_.adapter.peripheral-manager
    darwin.reserve-services manager.handle services_.size
    services_.size.repeat: | index/int |
      service/darwin.Resource := services_[index]
      service.clear darwin.SERVICE-ADD-SUCCEEDED | darwin.SERVICE-ADD-FAILED
      darwin.deploy-service service.handle index
      state := service.wait darwin.SERVICE-ADD-SUCCEEDED | darwin.SERVICE-ADD-FAILED
      if state & darwin.SERVICE-ADD-FAILED != 0: throw "GATT_SERVICE_ADD_FAILED"
    darwin.start-gatt-server manager.handle
    provider_.published_ = true
    advertise_ advertisement
    started_ = true
    // Centrals are anonymous on macOS: the session serves them all as one peer.
    peer_.set [UNKNOWN-PEER.copy, PLATFORM-IDENTIFIER]
    handles_.size.repeat: | index/int |
      entry/Entry_ := handles_[index]
      if entry.kind == "value" and entry.properties & 0x0c != 0: watchers_.add (task:: watch-writes_ (index + 1) entry)

  advertise_ advertisement/ByteArray -> none:
    manager := provider_.adapter.peripheral-manager
    decoded := decode-advertising advertisement
    catch: darwin.advertise-stop manager.handle
    manager.clear darwin.ADVERTISE-START-SUCCEEDED | darwin.ADVERTISE-START-FAILED
    darwin.advertise-start manager.handle decoded[0] decoded[1] 0 2 0
    state := manager.wait darwin.ADVERTISE-START-SUCCEEDED | darwin.ADVERTISE-START-FAILED
    if state & darwin.ADVERTISE-START-FAILED != 0: throw "GATT_ADVERTISING_FAILED"

  /** Delivers what centrals write to the application's written hook. */
  watch-writes_ handle/int entry/Entry_ -> none:
    resource := entry.resource
    catch:
      while true:
        resource.clear darwin.DATA-RECEIVED
        value := darwin.get-value resource.handle
        if value:
          values_[handle] = value
          catch: requests.written handle value
          continue
        resource.wait darwin.DATA-RECEIVED

  on-closed -> none:
    super
    watchers_.do: | watcher/Task | watcher.cancel
    if started_: catch: darwin.advertise-stop provider_.adapter.peripheral-manager.handle
    ended_.set true

// ---------------------------------------------------------------------------
// Advertising without a served database.

class AdvertisingSession extends rpc.Session:
  provider_/Provider
  started_/bool := false

  constructor .provider_ client/int data/ByteArray:
    super provider_ client
    advertise_ data

  is-released -> bool: return is-closed

  invoke index/int arguments/List -> any:
    if index == api.ADVERTISING-READY: return null
    if index == api.ADVERTISING-UPDATE:
      if arguments.size != 2: throw "INVALID_ARGUMENT"
      advertise_ arguments[0]
      return null
    if index == api.ADVERTISING-STOP:
      stop_
      return null
    return super index arguments

  advertise_ data/ByteArray -> none:
    manager := provider_.adapter.peripheral-manager
    decoded := decode-advertising data
    if started_: catch: darwin.advertise-stop manager.handle
    manager.clear darwin.ADVERTISE-START-SUCCEEDED | darwin.ADVERTISE-START-FAILED
    darwin.advertise-start manager.handle decoded[0] decoded[1] 0 0 0
    state := manager.wait darwin.ADVERTISE-START-SUCCEEDED | darwin.ADVERTISE-START-FAILED
    if state & darwin.ADVERTISE-START-FAILED != 0: throw "GATT_ADVERTISING_FAILED"
    started_ = true

  stop_ -> none:
    if not started_: return
    started_ = false
    catch: darwin.advertise-stop provider_.adapter.peripheral-manager.handle

  on-closed -> none:
    super
    stop_
