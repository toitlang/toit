// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import monitor

import .adapter
import .advertisement
import .uuid
import .local
import .remote
import .v2 as v2

/**
The `ble` package on `ble.v2`.

$Adapter, $Central, $Peripheral and the remote and local attribute classes
  are implemented here on the $v2.Adapter of the same device: the BLE
  provider built into the firmware, or one installed in the process on
  Linux. Applications keep using the `ble` package's classes and never
  import this library. Differences from what the package once did on
  NimBLE: the peripheral serves as many centrals at once as the provider
  allows (two on the built-in provider) and keeps advertising while
  connected; pairing policy belongs to the provider, so the `--bonding`
  and `--secure-connections` flags are advisory; `bonded-peers` lists what
  the provider chooses to list (none by default).
*/

/**
Opens the adapter through `ble.v2`: the device's BLE provider, or one
  installed in this process (`ble.v2.linux`, `ble.v2.darwin`). Throws
  "Unsupported platform" when there is none.
*/
host-adapter_ -> Adapter:
  adapter/v2.Adapter? := null
  error := catch: adapter = v2.Adapter
  if error: throw "Unsupported platform"
  return HostAdapter_ adapter

class HostAdapter_ extends Adapter:
  adapter_/v2.Adapter
  preferred-mtu_/int := 256
  closed_/bool := false

  constructor .adapter_:
    capabilities := adapter_.capabilities
    super.host_ (AdapterMetadata.private_ "toit-host" #[] capabilities.central capabilities.peripheral null)

  is-closed -> bool: return closed_

  close -> none:
    if closed_: return
    super
    closed_ = true
    adapter_.close

  create-central_ -> Central:
    return HostCentral_ this

  create-peripheral_ bonding/bool secure-connections/bool name/string? -> Peripheral:
    return HostPeripheral_ this name

  set-preferred-mtu mtu/int:
    if not 23 <= mtu <= 517: throw "INVALID_ARGUMENT"
    preferred-mtu_ = mtu

/** The identifier of a peer: its address type, then its address (the native ESP32 shape). */
identifier_ address/v2.Address -> ByteArray:
  identifier := ByteArray 7
  identifier[0] = address.type
  identifier.replace 1 address.bytes
  return identifier

// ---------------------------------------------------------------------------
// Central role.

class HostCentral_ extends Central:
  host-adapter_/HostAdapter_
  closed_/bool := false

  constructor .host-adapter_:
    super.host_ host-adapter_

  is-closed -> bool: return closed_

  close:
    if closed_: return
    super
    closed_ = true

  connect_ identifier/any secure/bool -> RemoteDevice:
    if identifier is not ByteArray: throw "INVALID_ARGUMENT"
    bytes/ByteArray := identifier
    address/v2.Address := ?
    if bytes.size == 7:
      address = v2.Address bytes[1..] --type=bytes[0]
    else if bytes.size == 6:
      address = v2.Address bytes
    else:
      throw "INVALID_ARGUMENT"
    connection := host-adapter_.adapter_.connect address
        --mtu=host-adapter_.preferred-mtu_
        --security=(secure ? v2.SECURITY-ENCRYPTED : v2.SECURITY-NONE)
    return HostRemoteDevice_ this identifier connection

  scan_ -> none
      --interval/int
      --window/int
      --duration/Duration?
      --limited-only/bool
      --active/bool
      [block]:
    scan-interval := interval == 0 ? null : (Duration --us=interval * 625)
    scan-window := window == 0 ? null : (Duration --us=window * 625)
    host-adapter_.adapter_.scan --duration=duration --active=active --duplicates --limited=limited-only --interval=scan-interval --window=scan-window: | report/v2.ScanReport |
      address := report.address
      if not address: continue.scan true
      connectable := report.is-connectable == true
      identifier/any := identifier_ address
      block.call (RemoteScannedDevice identifier (report.rssi or 0)
          --is-connectable=connectable
          --is-scan-response=report.is-scan-response
          --address-bytes=address.bytes
          --address-type=address.type
          (AdvertisementData.raw_ report.bytes --connectable=connectable))  // @no-warn
      true

  /** The bonded peers the provider lists, as identifiers for $connect. */
  bonded-peers -> List:
    return host-adapter_.adapter_.bonded-peers.map: | peer/v2.Peer | identifier_ peer.address

class HostRemoteDevice_ extends RemoteDevice:
  connection_/v2.Connection
  closed_/bool := false

  constructor manager/HostCentral_ identifier/Object .connection_:
    super.host_ manager identifier

  is-closed -> bool: return closed_

  discover-services_ service-uuids/List -> List:
    services := connection_.discover-services (service-uuids.is-empty ? null : service-uuids)
    return services.map: | service/v2.RemoteService | HostRemoteService_ this service

  disconnect_ --force/bool -> none:
    if closed_: return
    closed_ = true
    if not force: catch: connection_.disconnect
    connection_.close

  mtu -> int: return connection_.mtu

class HostRemoteService_ extends RemoteService:
  remote_/v2.RemoteService

  constructor device/HostRemoteDevice_ .remote_:
    super.host_ device remote_.uuid

  is-closed -> bool: return device.is-closed

  discover-characteristics_ characteristic-uuids/List -> List:
    characteristics := remote_.discover-characteristics (characteristic-uuids.is-empty ? null : characteristic-uuids)
    return characteristics.map: | characteristic/v2.RemoteCharacteristic |
      HostRemoteCharacteristic_ this characteristic

class HostRemoteCharacteristic_ extends RemoteCharacteristic:
  remote_/v2.RemoteCharacteristic
  subscription_/v2.Subscription? := null

  constructor service/HostRemoteService_ .remote_:
    super.host_ service remote_.uuid remote_.properties

  is-closed -> bool: return service.is-closed

  close_ -> none:
    catch: set-subscription_ false
    super

  write_ value/io.Data --expects-response/bool:
    remote_.write (ByteArray.from value) --response=expects-response

  request-read_ -> ByteArray: return remote_.read

  wait-for-notification_ -> ByteArray?:
    subscription := subscription_
    if not subscription: throw "Characteristic is not subscribed"
    return subscription.receive

  set-subscription_ subscribe/bool -> none:
    if subscribe:
      if subscription_: return
      // Notifications when the characteristic offers them, indications otherwise.
      indications := properties & CHARACTERISTIC-PROPERTY-NOTIFY == 0
      subscription_ = remote_.subscribe --queue-limit=32 --indications=indications
    else:
      subscription := subscription_
      subscription_ = null
      if subscription: subscription.close

  discover-descriptors_ -> List:
    return remote_.discover-descriptors.map: | descriptor/v2.RemoteDescriptor |
      HostRemoteDescriptor_ this descriptor

  mtu -> int: return service.device.mtu

  handle -> int: return remote_.handle

class HostRemoteDescriptor_ extends RemoteDescriptor:
  remote_/v2.RemoteDescriptor

  constructor characteristic/HostRemoteCharacteristic_ .remote_:
    super.host_ characteristic remote_.uuid

  is-closed -> bool: return characteristic.is-closed

  write_ value/io.Data --expects-response/bool:
    remote_.write (ByteArray.from value)

  request-read_ -> ByteArray: return remote_.read

  handle -> int: return remote_.handle

// ---------------------------------------------------------------------------
// Peripheral role.

class HostPeripheral_ extends Peripheral:
  host-adapter_/HostAdapter_
  name_/string?
  server_/v2.GattServer ::= v2.GattServer
  peripheral_/v2.Peripheral? := null
  broadcast_/v2.Broadcast? := null
  accepting_/Task? := null
  closed_/bool := false

  constructor .host-adapter_ .name_:
    super.host_ host-adapter_

  is-closed -> bool: return closed_

  close:
    if closed_: return
    super
    closed_ = true
    stop-advertise
    if peripheral_:
      peripheral_.close
      peripheral_ = null

  create-service_ uuid/BleUuid -> LocalService:
    return HostLocalService_ this (server_.add-service uuid)

  deploy_ -> none:
    // The provider builds the database for every central that connects;
    // nothing happens before advertising starts.

  start-advertise
      data/Advertisement
      --scan-response/Advertisement?=null
      --interval/Duration=Peripheral.DEFAULT-INTERVAL
      --connection-mode/int=BLE-CONNECT-MODE-NONE:
    if closed_: throw "BLE_CLOSED"
    if broadcast_ or accepting_: throw "Already advertising"
    if connection-mode == BLE-CONNECT-MODE-NONE:
      broadcast_ = host-adapter_.adapter_.advertise data --scan-response=scan-response --interval=interval
      return
    if connection-mode != BLE-CONNECT-MODE-UNDIRECTIONAL: throw "UNSUPPORTED"
    if not peripheral_:
      timeout := Duration --ms=LocalService.DEFAULT-WRITE-TIMEOUT-MS
      peripheral_ = host-adapter_.adapter_.peripheral server_ --advertisement=data --scan-response=scan-response --interval=interval --mtu=host-adapter_.preferred-mtu_ --handler-timeout=timeout
          --name=(name_ or "Toit")
    else:
      peripheral_.set-advertisement data --scan-response=scan-response
    accepting_ = task:: accept-connections_

  stop-advertise:
    if broadcast_:
      broadcast_.stop
      broadcast_ = null
    // Ending the wait for the next central stops advertising; connected
    // centrals stay connected.
    accepting := accepting_
    accepting_ = null
    if accepting and accepting != Task.current: accepting.cancel

  /** Accepts centrals while advertising is on; each one is served until it leaves. */
  accept-connections_ -> none:
    peripheral := peripheral_
    while peripheral_ == peripheral and not closed_:
      connection/v2.Connection? := null
      error := catch: connection = peripheral.accept
      if not connection:
        if error == CANCELED-ERROR or error == "BLE_CLOSED": return
        // The provider could not advertise right now (for example while it
        // still releases a previous link); retry at a gentle pace.
        sleep --ms=250
        continue
      task:: watch-connection_ connection

  watch-connection_ connection/v2.Connection -> none:
    catch: connection.wait-closed
    connection.close
    peripheral := peripheral_
    if peripheral and peripheral.connections.is-empty:
      services_.do: | service/HostLocalService_ | service.disconnected_

  /** The handle of a server element on the first connected central, or 0. */
  handle-of_ element -> int:
    peripheral := peripheral_
    if not peripheral: return 0
    peripheral.links_.do: | link/v2.PeripheralLink_ |
      handle := link.handle-of element
      if handle: return handle
    return 0

class HostLocalService_ extends LocalService:
  service_/v2.Service

  constructor peripheral/HostPeripheral_ .service_:
    super.host_ peripheral service_.uuid

  is-closed -> bool: return peripheral-manager.is-closed

  create-characteristic_ uuid/BleUuid properties/int permissions/int value/io.Data? read-timeout-ms/int -> LocalCharacteristic:
    return HostLocalCharacteristic_ this uuid properties permissions value read-timeout-ms

  disconnected_ -> none:
    characteristics_.do: | characteristic/HostLocalCharacteristic_ | characteristic.disconnected_

/** A read or write that a handler block answers; see $HostLocalCharacteristic_.handle-request_. */
class Request_:
  /** The proposed value of a write; null for a read. */
  value/ByteArray?
  answer_/monitor.Latch ::= monitor.Latch

  constructor .value:

  /** Waits for the answer: the value for a read, null for an accepted write. */
  wait -> ByteArray?: return answer_.get

  reply value/ByteArray? -> none:
    if not answer_.has-value: answer_.set value

  fail error -> none:
    if not answer_.has-value: answer_.set error --exception

class HostLocalCharacteristic_ extends LocalCharacteristic:
  peripheral_/HostPeripheral_
  characteristic_/v2.Characteristic? := null
  written_/Values_ ::= Values_
  requests_/Values_? := null
  handling-writes_/bool := false

  constructor service/HostLocalService_ uuid/BleUuid properties/int permissions/int value/io.Data? read-timeout-ms/int:
    peripheral_ = service.peripheral-manager as HostPeripheral_
    super.host_ service uuid properties permissions read-timeout-ms
    readable := properties & CHARACTERISTIC-PROPERTY-READ != 0
    writable := properties & CHARACTERISTIC-PROPERTY-WRITE != 0
    command := properties & CHARACTERISTIC-PROPERTY-WRITE-WITHOUT-RESPONSE != 0
    encrypted := permissions & (CHARACTERISTIC-PERMISSION-READ-ENCRYPTED | CHARACTERISTIC-PERMISSION-WRITE-ENCRYPTED) != 0
    // Every read and write comes through this object: a read handler answers
    // reads, a write handler sees writes before their response leaves, and
    // without handlers the value is served and written values are queued.
    // Write commands have no response to hold back, so they arrive written.
    on-read := readable ? (:: | connection/v2.Connection | serve-read_) : null
    validate := writable ? (:: | connection/v2.Connection value/ByteArray | serve-validate_ value) : null
    on-write := (writable or command) ? (:: | connection/v2.Connection value/ByteArray | serve-written_ value) : null
    characteristic_ = service.service_.add-characteristic uuid --read=readable --write=writable --write-without-response=command --on-read=on-read --validate=validate --on-write=on-write
        --notify=(properties & CHARACTERISTIC-PROPERTY-NOTIFY != 0)
        --indicate=(properties & CHARACTERISTIC-PROPERTY-INDICATE != 0)
        --value=(value ? (ByteArray.from value) : #[])
        --security=(encrypted ? v2.SECURITY-ENCRYPTED : v2.SECURITY-NONE)

  is-closed -> bool: return service.is-closed

  disconnected_ -> none:
    requests := requests_
    if requests: requests.fail "Disconnected"

  set-value value/io.Data?:
    characteristic_.value = value ? (ByteArray.from value) : #[]

  write_ value/io.Data --set-value/bool:
    bytes := ByteArray.from value
    previous := characteristic_.value
    notifies := properties & CHARACTERISTIC-PROPERTY-NOTIFY != 0
    indicates := properties & CHARACTERISTIC-PROPERTY-INDICATE != 0
    if not notifies and not indicates:
      if set-value: characteristic_.value = bytes
      return
    if notifies:
      characteristic_.notify bytes
    else:
      peripheral := peripheral_.peripheral_
      if peripheral:
        peripheral.connections.do: | connection/v2.Connection |
          // A central that leaves meanwhile is left to its own cleanup.
          catch: characteristic_.indicate bytes --to=connection
    if not set-value: characteristic_.value = previous

  read_ -> ByteArray: return written_.take

  handle-request_ --for-read/bool --timeout-ms/int [block]:
    if requests_: throw "Handler already active"
    requests := Values_
    requests_ = requests
    handling-writes_ = not for-read
    try:
      while true:
        request := null
        error := catch: request = requests.take
        if error: return
        if for-read:
          value := block.call
          request.reply (ByteArray.from value)
        else if request is ByteArray:
          // A committed write command: the block sees it, nothing to answer.
          block.call request
        else:
          block.call request.value
          request.reply null
    finally:
      requests_ = null
      handling-writes_ = false

  serve-read_ -> ByteArray:
    requests := requests_
    if requests and not handling-writes_:
      request := Request_ null
      requests.add request
      return request.wait
    return characteristic_.value

  serve-validate_ value/ByteArray -> none:
    requests := requests_
    if requests and handling-writes_:
      request := Request_ value
      requests.add request
      request.wait

  serve-written_ value/ByteArray -> none:
    requests := requests_
    if requests and handling-writes_:
      // Validated writes reached the handler already; commands arrive here.
      if properties & CHARACTERISTIC-PROPERTY-WRITE == 0: requests.add value
      return
    written_.add value

  create-descriptor_ uuid/BleUuid properties/int permissions/int value/io.Data? -> LocalDescriptor:
    return HostLocalDescriptor_ this uuid properties permissions value

  handle -> int: return peripheral_.handle-of_ characteristic_

class HostLocalDescriptor_ extends LocalDescriptor:
  descriptor_/v2.Descriptor

  constructor characteristic/HostLocalCharacteristic_ uuid/BleUuid properties/int permissions/int value/io.Data?:
    encrypted := permissions & (CHARACTERISTIC-PERMISSION-READ-ENCRYPTED | CHARACTERISTIC-PERMISSION-WRITE-ENCRYPTED) != 0
    descriptor_ = characteristic.characteristic_.add-descriptor uuid --value=(value ? (ByteArray.from value) : #[])
        --read=(properties & CHARACTERISTIC-PROPERTY-READ != 0)
        --write=(properties & CHARACTERISTIC-PROPERTY-WRITE != 0)
        --security=(encrypted ? v2.SECURITY-ENCRYPTED : v2.SECURITY-NONE)
    super.host_ characteristic uuid properties permissions

  is-closed -> bool: return characteristic.is-closed

  set-value_ value/io.Data:
    descriptor_.value = ByteArray.from value

  read_ -> ByteArray: return descriptor_.value

  handle -> int:
    peripheral := characteristic.service.peripheral-manager as HostPeripheral_
    return peripheral.handle-of_ descriptor_

/** A bounded queue that fails its takers when its source ends. */
monitor Values_:
  queue_/List := []
  error_ := null

  add value -> none:
    if error_: throw error_
    if queue_.size >= 32: throw "Queue overflow"
    queue_.add value

  take -> any:
    await: error_ or not queue_.is-empty
    if queue_.is-empty: throw error_
    return queue_.remove --at=0

  fail error -> none:
    if error_: return
    error_ = error
