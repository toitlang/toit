// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
The `ble` package on the Toit host.

Firmware without a native BLE host (a controller-only ESP32 image, or a Linux
  host) serves the same public API through the BLE service provider of
  `ble.experimental.service`. $Adapter picks this backend when the native one
  is unavailable and a provider is installed. Differences from the native
  backend are noted on each class; the main ones are that the peripheral
  accepts one connection at a time (advertising resumes after each
  disconnect) and that pairing policy belongs to the provider, so the
  `--bonding` and `--secure-connections` flags are advisory.
*/

import io
import monitor

import .ble
import .local
import .remote
import .experimental.service.client as rpc

/** Opens the Toit host backend, or throws "Unsupported platform" without a provider. */
host-adapter_ -> Adapter:
  client := rpc.Client
  error := catch: client.open --timeout=(Duration --s=2)
  if error: throw "Unsupported platform"
  return HostAdapter_ client

class HostAdapter_ extends Adapter:
  client_/rpc.Client
  preferred-mtu_/int := 256
  closed_/bool := false

  constructor .client_:
    capabilities := client_.capabilities
    super.host_ (AdapterMetadata.private_ "toit-host" #[] capabilities.gatt-central capabilities.gatt-peripheral null)

  is-closed -> bool: return closed_

  close -> none:
    if closed_: return
    super
    closed_ = true
    client_.close

  create-central_ -> Central:
    return HostCentral_ this

  create-peripheral_ bonding/bool secure-connections/bool name/string? -> Peripheral:
    return HostPeripheral_ this name

  set-preferred-mtu mtu/int:
    if not 23 <= mtu <= 517: throw "INVALID_ARGUMENT"
    preferred-mtu_ = mtu

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
    type := 0
    address/ByteArray := ?
    if bytes.size == 7:
      type = bytes[0]
      address = bytes[1..].copy
    else if bytes.size == 6:
      address = bytes.copy
    else:
      throw "INVALID_ARGUMENT"
    // Identity address types resolve to their public or random kind.
    if type >= 2: type -= 2
    connection := host-adapter_.client_.connect address --address-type=type
        --mtu-limit=host-adapter_.preferred-mtu_
        --require-encryption=secure
    return HostRemoteDevice_ this identifier connection

  scan_ -> none
      --interval/int
      --window/int
      --duration/Duration?
      --limited-only/bool
      --active/bool
      [block]:
    host-adapter_.client_.scan
        --duration=(duration or (Duration --s=10))
        --continuous=(duration == null)
        --active=active
        --interval=(interval == 0 ? 16 : interval)
        --window=(window == 0 ? 16 : window)
        --no-filter-duplicates
        --limited-only=limited-only: | report/rpc.ScanReport |
      // The identifier keeps the native ESP32 shape: address type, then address.
      identifier/any := ByteArray 7
      identifier[0] = report.address-type
      identifier.replace 1 report.address
      connectable := report.connectable
      block.call (RemoteScannedDevice identifier (report.rssi or 0)
          --is-connectable=(connectable == true)
          --is-scan-response=(report.scan-response == true)
          --address-bytes=report.address
          --address-type=report.address-type
          (AdvertisementData.raw_ report.data --connectable=(connectable == true)))  // @no-warn
      true

  /** The provider owns bonds; it does not expose them through this API. */
  bonded-peers -> List: return []

class HostRemoteDevice_ extends RemoteDevice:
  connection_/rpc.Connection
  closed_/bool := false

  constructor manager/HostCentral_ identifier/Object .connection_:
    super.host_ manager identifier

  is-closed -> bool: return closed_

  discover-services_ service-uuids/List -> List:
    wanted := service-uuids.map: | uuid/BleUuid | uuid.to-byte-array --reversed
    records := connection_.database.discover-services
    result := []
    records.do: | record/rpc.ServiceRecord |
      if wanted.is-empty or wanted.contains record.uuid:
        result.add (HostRemoteService_ this (BleUuid.from-reversed record.uuid) record)
    return result

  disconnect_ --force/bool -> none:
    if closed_: return
    closed_ = true
    if force:
      connection_.close
    else:
      connection_.disconnect

  mtu -> int: return connection_.info[2]

class HostRemoteService_ extends RemoteService:
  record_/rpc.ServiceRecord

  constructor device/HostRemoteDevice_ uuid/BleUuid .record_:
    super.host_ device uuid

  is-closed -> bool: return device.is-closed

  discover-characteristics_ characteristic-uuids/List -> List:
    wanted := characteristic-uuids.map: | uuid/BleUuid | uuid.to-byte-array --reversed
    result := []
    record_.characteristics.do: | record/rpc.CharacteristicRecord |
      if wanted.is-empty or wanted.contains record.uuid:
        result.add (HostRemoteCharacteristic_ this (BleUuid.from-reversed record.uuid) record.properties record)
    return result

class HostRemoteCharacteristic_ extends RemoteCharacteristic:
  record_/rpc.CharacteristicRecord
  notifications_/Values_? := null
  subscription-task_/Task? := null

  constructor service/HostRemoteService_ uuid/BleUuid properties/int .record_:
    super.host_ service uuid properties

  is-closed -> bool: return service.is-closed

  close_ -> none:
    catch: set-subscription_ false
    super

  write_ value/io.Data --expects-response/bool:
    bytes := ByteArray.from value
    if expects-response: record_.write bytes
    else: record_.write-command bytes

  request-read_ -> ByteArray: return record_.read

  wait-for-notification_ -> ByteArray?:
    values := notifications_
    if not values: throw "Characteristic is not subscribed"
    return values.take

  set-subscription_ subscribe/bool -> none:
    if subscribe:
      if notifications_: return
      // Notifications only when the characteristic offers them, indications otherwise.
      indications := properties & CHARACTERISTIC-PROPERTY-NOTIFY == 0
      values := Values_
      ready := monitor.Latch
      notifications_ = values
      subscription-task_ = task::
        error := catch:
          record_.subscribe --indications=indications --queue-limit=32: | stream/rpc.Subscription |
            ready.set true
            while true: values.add stream.receive
        critical-do --no-respect-deadline:
          values.fail (error or "Disconnected")
          if not ready.has-value: ready.set (error or "Disconnected") --exception
      failure := catch: ready.get
      if failure:
        notifications_ = null
        subscription-task_ = null
        throw failure
    else:
      if not notifications_: return
      worker := subscription-task_
      subscription-task_ = null
      notifications_ = null
      if worker: worker.cancel

  discover-descriptors_ -> List:
    return record_.descriptors.map: | record/rpc.DescriptorRecord |
      HostRemoteDescriptor_ this (BleUuid.from-reversed record.uuid) record

  mtu -> int: return service.device.mtu

  handle -> int: return record_.handle

class HostRemoteDescriptor_ extends RemoteDescriptor:
  record_/rpc.DescriptorRecord

  constructor characteristic/HostRemoteCharacteristic_ uuid/BleUuid .record_:
    super.host_ characteristic uuid

  is-closed -> bool: return characteristic.is-closed

  write_ value/io.Data --expects-response/bool:
    record_.write (ByteArray.from value)

  request-read_ -> ByteArray: return record_.read

  handle -> int: return record_.handle

// ---------------------------------------------------------------------------
// Peripheral role.

class HostPeripheral_ extends Peripheral:
  host-adapter_/HostAdapter_
  name_/string?
  closed_/bool := false
  advertising_/rpc.Advertising? := null
  session_/rpc.Session? := null
  connected_/bool := false
  advertisement_/ByteArray? := null
  scan-response_/ByteArray? := null
  interval_/int := 160
  advertising-active_/bool := false
  worker_/Task? := null

  constructor .host-adapter_ .name_:
    super.host_ host-adapter_

  is-closed -> bool: return closed_

  close:
    if closed_: return
    super
    closed_ = true

  create-service_ uuid/BleUuid -> LocalService:
    return HostLocalService_ this uuid

  deploy_ -> none:
    // The database is built on the provider for every connection; nothing
    // happens before advertising starts.

  start-advertise
      data/Advertisement
      --scan-response/Advertisement?=null
      --interval/Duration=Peripheral.DEFAULT-INTERVAL
      --connection-mode/int=BLE-CONNECT-MODE-NONE:
    if advertising-active_ or advertising_: throw "Already advertising"
    raw := data.to-raw
    if raw.size > 31: throw "INVALID_ARGUMENT"
    response-raw/ByteArray := #[]
    if scan-response:
      response-raw = scan-response.to-raw
      if response-raw.size > 31: throw "INVALID_ARGUMENT"
    units := interval.in-us / 625
    if not 32 <= units <= 16384: throw "INVALID_ARGUMENT"
    if connection-mode == BLE-CONNECT-MODE-NONE:
      advertising_ = host-adapter_.client_.start-advertising raw
          --scan-response=response-raw
          --interval=(units)
          --scannable=(not response-raw.is-empty)
      return
    if connection-mode != BLE-CONNECT-MODE-UNDIRECTIONAL: throw "UNSUPPORTED"
    advertisement_ = raw
    scan-response_ = response-raw
    interval_ = units
    advertising-active_ = true
    started := monitor.Latch
    worker_ = task:: serve-connections_ started
    error := started.get
    if error: throw error

  stop-advertise:
    advertising-active_ = false
    if advertising_:
      advertising_.stop
      advertising_ = null
    // A session that still waits for a peer ends now; a connected one runs on.
    if session_ and not connected_:
      catch: session_.close

  /**
  Serves one peripheral session after another while advertising is active.

  Each session carries a fresh copy of the database, accepts one central,
    serves its requests until it disconnects, and is then replaced.
  */
  serve-connections_ started/monitor.Latch -> none:
    first := true
    while advertising-active_ and not closed_:
      session/rpc.Session? := null
      error := catch:
        session = build-session_
        session.start advertisement_ --scan-response=scan-response_ --interval=interval_
      if error:
        if first: started.set error
        session_ = null
        return
      session_ = session
      if first:
        first = false
        started.set null
      error = catch:
        session.peer
        connected_ = true
        session.serve
            (: | request/rpc.Request | serve-read_ request)
            (: | request/rpc.Request | serve-validate_ request)
            (: | handle/int value/ByteArray | serve-written_ handle value)
      connected_ = false
      session_ = null
      services_.do: | service/HostLocalService_ | service.disconnected_

  build-session_ -> rpc.Session:
    timeout := Duration --ms=LocalService.DEFAULT-WRITE-TIMEOUT-MS
    session := host-adapter_.client_.configure --value-limit=512 --mtu-limit=host-adapter_.preferred-mtu_
        --handler-timeout=timeout
    services_.do: | service/HostLocalService_ | service.build_ session
    return session

  find-element_ handle/int -> HostElement_?:
    services_.do: | service/HostLocalService_ |
      element := service.find_ handle
      if element: return element
    return null

  serve-read_ request/rpc.Request -> none:
    element := find-element_ request.handle
    if not element:
      request.reject 0x0a
      return
    element.serve-read_ request

  serve-validate_ request/rpc.Request -> none:
    element := find-element_ request.handle
    if not element:
      request.reject 0x0a
      return
    element.serve-validate_ request

  serve-written_ handle/int value/ByteArray -> none:
    element := find-element_ handle
    if element: element.serve-written_ value

class HostLocalService_ extends LocalService:
  constructor peripheral/HostPeripheral_ uuid/BleUuid:
    super.host_ peripheral uuid

  is-closed -> bool: return peripheral-manager.is-closed

  create-characteristic_ uuid/BleUuid properties/int permissions/int value/io.Data? read-timeout-ms/int -> LocalCharacteristic:
    return HostLocalCharacteristic_ this uuid properties permissions value read-timeout-ms

  build_ session/rpc.Session -> none:
    session.add-service (uuid.to-byte-array --reversed)
    characteristics_.do: | characteristic/HostLocalCharacteristic_ | characteristic.build_ session

  find_ handle/int -> HostElement_?:
    characteristics_.do: | characteristic/HostLocalCharacteristic_ |
      element := characteristic.find_ handle
      if element: return element
    return null

  disconnected_ -> none:
    characteristics_.do: | characteristic/HostLocalCharacteristic_ | characteristic.disconnected_

/** What a characteristic and a descriptor share on the host: a handle, a value and request queues. */
interface HostElement_:
  serve-read_ request/rpc.Request -> none
  serve-validate_ request/rpc.Request -> none
  serve-written_ value/ByteArray -> none

class HostLocalCharacteristic_ extends LocalCharacteristic implements HostElement_:
  peripheral_/HostPeripheral_
  value_/ByteArray := #[]
  handle_/int := 0
  written_/Values_ ::= Values_
  requests_/Values_? := null
  handling-writes_/bool := false

  constructor service/HostLocalService_ uuid/BleUuid properties/int permissions/int value/io.Data? read-timeout-ms/int:
    peripheral_ = service.peripheral-manager as HostPeripheral_
    value_ = value ? (ByteArray.from value) : #[]
    super.host_ service uuid properties permissions read-timeout-ms

  is-closed -> bool: return service.is-closed

  build_ session/rpc.Session -> none:
    readable := properties & CHARACTERISTIC-PROPERTY-READ != 0
    writable := properties & CHARACTERISTIC-PROPERTY-WRITE != 0
    command := properties & CHARACTERISTIC-PROPERTY-WRITE-WITHOUT-RESPONSE != 0
    encrypted := permissions & (CHARACTERISTIC-PERMISSION-READ-ENCRYPTED | CHARACTERISTIC-PERMISSION-WRITE-ENCRYPTED) != 0
    // Writes with a response go through validation so a write handler can
    // process the value before the response leaves. Write commands have no
    // response to hold back, so the provider commits them at once and a
    // disconnect right after the command cannot lose them.
    handle_ = session.add-characteristic (uuid.to-byte-array --reversed)
        --read=readable
        --write=writable
        --write-command=command
        --notify=(properties & CHARACTERISTIC-PROPERTY-NOTIFY != 0)
        --indicate=(properties & CHARACTERISTIC-PROPERTY-INDICATE != 0)
        --dynamic-read=readable
        --validate-write=writable
        --encrypted=encrypted
        --value=value_
    descriptors_.do: | descriptor/HostLocalDescriptor_ | descriptor.build_ session handle_

  find_ handle/int -> HostElement_?:
    if handle == handle_ and handle_ != 0: return this
    descriptors_.do: | descriptor/HostLocalDescriptor_ |
      if descriptor.handle_ == handle and handle != 0: return descriptor
    return null

  disconnected_ -> none:
    requests := requests_
    if requests: requests.fail "Disconnected"

  set-value value/io.Data?:
    value_ = value ? (ByteArray.from value) : #[]
    session := peripheral_.session_
    if session and peripheral_.connected_ and handle_ != 0: session.set-value handle_ value_

  write_ value/io.Data --set-value/bool:
    bytes := ByteArray.from value
    previous := value_
    if set-value: value_ = bytes
    session := peripheral_.session_
    if not session or not peripheral_.connected_ or handle_ == 0: return
    if properties & (CHARACTERISTIC-PROPERTY-NOTIFY | CHARACTERISTIC-PROPERTY-INDICATE) == 0:
      if set-value: session.set-value handle_ bytes
      return
    session.set-value handle_ bytes
    if properties & CHARACTERISTIC-PROPERTY-NOTIFY != 0:
      session.notify handle_
    else:
      receipt := session.indicate handle_
      if receipt: receipt.wait
    if not set-value: session.set-value handle_ previous

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
          request.accept
    finally:
      requests_ = null
      handling-writes_ = false

  serve-read_ request/rpc.Request -> none:
    requests := requests_
    if requests and not handling-writes_:
      requests.add request
      request.wait-replied_
    else:
      request.reply value_

  serve-validate_ request/rpc.Request -> none:
    requests := requests_
    if requests and handling-writes_:
      requests.add request
      request.wait-replied_
    else:
      request.accept

  serve-written_ value/ByteArray -> none:
    value_ = value
    requests := requests_
    if requests and handling-writes_:
      // Validated writes reached the handler already; commands arrive here.
      if properties & CHARACTERISTIC-PROPERTY-WRITE == 0: requests.add value
      return
    written_.add value

  create-descriptor_ uuid/BleUuid properties/int permissions/int value/io.Data? -> LocalDescriptor:
    return HostLocalDescriptor_ this uuid properties permissions value

  handle -> int: return handle_

class HostLocalDescriptor_ extends LocalDescriptor implements HostElement_:
  value_/ByteArray := #[]
  handle_/int := 0
  written_/Values_ ::= Values_

  constructor characteristic/HostLocalCharacteristic_ uuid/BleUuid properties/int permissions/int value/io.Data?:
    value_ = value ? (ByteArray.from value) : #[]
    super.host_ characteristic uuid properties permissions

  is-closed -> bool: return characteristic.is-closed

  build_ session/rpc.Session characteristic-handle/int -> none:
    handle_ = session.add-descriptor characteristic-handle (uuid.to-byte-array --reversed)
        --read=(properties & CHARACTERISTIC-PROPERTY-READ != 0)
        --write=(properties & CHARACTERISTIC-PROPERTY-WRITE != 0)
        --encrypted=(permissions & (CHARACTERISTIC-PERMISSION-READ-ENCRYPTED | CHARACTERISTIC-PERMISSION-WRITE-ENCRYPTED) != 0)
        --value=value_

  set-value_ value/io.Data:
    value_ = ByteArray.from value

  read_ -> ByteArray: return written_.take

  serve-read_ request/rpc.Request -> none: request.reply value_
  serve-validate_ request/rpc.Request -> none: request.accept
  serve-written_ value/ByteArray -> none:
    value_ = value
    written_.add value

  handle -> int: return handle_

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
