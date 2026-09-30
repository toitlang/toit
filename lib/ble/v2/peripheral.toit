// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ..ble show BleUuid Advertisement DataBlock
import monitor

import ..experimental.service.client as rpc
import ..experimental.service.api as api
import .adapter show Adapter
import .connection
import .types

/**
The peripheral role of the application API (`ble.v2`).

A $GattServer defines this device's $Service, $Characteristic and
  $Descriptor attributes; $Adapter.peripheral serves it and returns a
  $Peripheral, which advertises and hands out the $Connection of each
  central that connects through $Peripheral.accept. Values, notifications
  and indications are managed on the $Characteristic, which knows every
  connected central.
*/

/**
A GATT server's definition: services, characteristics and descriptors.

Define it once and hand it to $Adapter.peripheral. The provider builds a
  database from it for every connected central, so all centrals see the same
  attributes and the same values.
*/
class GattServer:
  services_/List ::= []
  peripheral_/Peripheral? := null

  /**
  Adds a primary service, or a $secondary one: centrals find a secondary
    service only through a service that includes it ($Service.include).
  */
  add-service uuid/BleUuid --secondary/bool=false -> Service:
    if peripheral_: throw "BLE_SERVER_IN_USE"
    service := Service this uuid --secondary=secondary
    services_.add service
    return service

  services -> List: return services_.copy

  connections_ -> List: return peripheral_ ? peripheral_.links_ : []

  /**
  The attributes the provider's database needs, its nine default ones
    included (the Robust Caching pair comes on top).
  */
  attribute-count_ -> int:
    count := 9
    services_.do: | service/Service |
      count += 1 + service.includes_.size
      service.characteristics_.do: | characteristic/Characteristic |
        count += 2
        if characteristic.notify_ or characteristic.indicate_: count++
        characteristic.descriptors_.do: | descriptor/Descriptor |
          count++
          // A writable User Description brings Extended Properties along.
          if descriptor.write_ and descriptor.uuid == (BleUuid "2901"): count++
    return count

/** A service in a $GattServer. */
class Service:
  server/GattServer
  uuid/BleUuid
  is-secondary/bool
  includes_/List ::= []
  characteristics_/List ::= []

  constructor .server .uuid --secondary/bool:
    is-secondary = secondary

  /**
  Includes $other in this service.

  An include says that this service builds on $other. A central that asks
    for this service's included services finds $other there, with its
    attributes, without searching all services. It is the only way for a
    central to find a secondary service ($GattServer.add-service with
    `--secondary`), since centrals do not find secondary services on their
    own.

  $other must belong to the same server and must have been added before this
    service.
  */
  include other/Service -> none:
    if server.peripheral_: throw "BLE_SERVER_IN_USE"
    index := server.services_.index-of other
    if other.server != server or index < 0 or index >= (server.services_.index-of this) or
        includes_.contains other:
      throw "INVALID_ARGUMENT"
    includes_.add other

  includes -> List: return includes_.copy

  /**
  Adds a characteristic.

  The flags say what centrals may do: $read, $write (with response),
    $write-without-response, $notify and $indicate. $security is the level
    a central's link needs to read or write the value.

  Without handlers, reads return $value and writes replace it. $on-read,
    given the $Connection, returns the value for each read instead. $validate,
    given the connection and the proposed value, runs before a write is
    applied; throwing an $AttError refuses it. $on-write, given the connection
    and the new value, runs after a write was applied.
  */
  add-characteristic uuid/BleUuid
      --read/bool=false
      --write/bool=false
      --write-without-response/bool=false
      --notify/bool=false
      --indicate/bool=false
      --value/ByteArray=#[]
      --security/int=SECURITY-NONE
      --on-read/Lambda?=null
      --validate/Lambda?=null
      --on-write/Lambda?=null
      -> Characteristic:
    if server.peripheral_: throw "BLE_SERVER_IN_USE"
    if not SECURITY-NONE <= security <= SECURITY-AUTHENTICATED: throw "INVALID_ARGUMENT"
    if on-read and not read: throw "INVALID_ARGUMENT"
    if (validate or on-write) and not write and not write-without-response: throw "INVALID_ARGUMENT"
    if value.size > 512: throw "INVALID_ARGUMENT"
    characteristic := Characteristic this uuid
        --read=read
        --write=write
        --write-without-response=write-without-response
        --notify=notify
        --indicate=indicate
        --value=value
        --security=security
        --on-read=on-read
        --validate=validate
        --on-write=on-write
    characteristics_.add characteristic
    return characteristic

  characteristics -> List: return characteristics_.copy

  /**
  Adds this service to $session. $declarations holds the declaration handles
    of the server's services by index, those before this one filled in.
  */
  build_ session/rpc.Session handles/Map declarations/List -> none:
    services := server.services_
    declarations[services.index-of this] = session.add-service (uuid.to-byte-array --reversed)
        --secondary=is-secondary
    includes_.do: | other/Service | session.include-service declarations[services.index-of other]
    characteristics_.do: | characteristic/Characteristic |
      characteristic.build_ session handles

/** A characteristic in a $GattServer. */
class Characteristic:
  service/Service
  uuid/BleUuid
  read_/bool
  write_/bool
  write-without-response_/bool
  notify_/bool
  indicate_/bool
  security_/int
  on-read_/Lambda?
  validate_/Lambda?
  on-write_/Lambda?
  value_/ByteArray := ?
  descriptors_/List ::= []

  constructor .service .uuid --read/bool --write/bool --write-without-response/bool
      --notify/bool --indicate/bool --value/ByteArray --security/int
      --on-read/Lambda? --validate/Lambda? --on-write/Lambda?:
    read_ = read
    write_ = write
    write-without-response_ = write-without-response
    notify_ = notify
    indicate_ = indicate
    security_ = security
    on-read_ = on-read
    validate_ = validate
    on-write_ = on-write
    value_ = value.copy

  /** The current value: the last one set or written. */
  value -> ByteArray: return value_.copy

  /** Replaces the value for every central, without notifying anyone. */
  value= value/ByteArray -> none:
    if value.size > 512: throw "INVALID_ARGUMENT"
    value_ = value.copy
    service.server.connections_.do: | link/PeripheralLink_ |
      handle := link.handle-of this
      if handle: catch: link.session.set-value handle value_

  /**
  Sets the value and notifies subscribed centrals, or only the one on $to.

  Returns how many centrals were sent the notification; a central that has
    not subscribed gets none. The value must fit the MTU - 3 of each link.
  */
  notify value/ByteArray --to/Connection?=null -> int:
    return notify-values [value] --to=to

  /**
  Notifies each of $values in order, in one round trip per central.

  Up to 32 values. Returns the number of centrals that got all of them.
    Leaves the last value as the characteristic's value.
  */
  notify-values values/List --to/Connection?=null -> int:
    if not notify_: throw "BLE_NOT_NOTIFIABLE"
    if values.is-empty: return 0
    value_ = (values.last as ByteArray).copy
    count := 0
    service.server.connections_.do: | link/PeripheralLink_ |
      if to and link.connection != to: continue.do
      handle := link.handle-of this
      if handle:
        sent := 0
        catch: sent = link.session.notify-values handle values
        if sent == values.size: count++
    return count

  /**
  Sets the value and indicates it to the central on $to, waiting for its
    confirmation.

  Returns false when the central has not subscribed to indications.
  */
  indicate value/ByteArray --to/Connection -> bool:
    if not indicate_: throw "BLE_NOT_INDICATABLE"
    value_ = value.copy
    service.server.connections_.do: | link/PeripheralLink_ |
      if link.connection != to: continue.do
      handle := link.handle-of this
      if not handle: return false
      link.session.set-value handle value_
      receipt := link.session.indicate handle
      if not receipt: return false
      receipt.wait
      return true
    throw "BLE_CLOSED"

  /** Adds a descriptor with a fixed or centrally writable value. */
  add-descriptor uuid/BleUuid --value/ByteArray=#[] --read/bool=true --write/bool=false
      --security/int=SECURITY-NONE -> Descriptor:
    if service.server.peripheral_: throw "BLE_SERVER_IN_USE"
    descriptor := Descriptor this uuid value --read=read --write=write --security=security
    descriptors_.add descriptor
    return descriptor

  build_ session/rpc.Session handles/Map -> none:
    handle := session.add-characteristic (uuid.to-byte-array --reversed)
        --read=read_
        --write=write_
        --write-command=write-without-response_
        --notify=notify_
        --indicate=indicate_
        --dynamic-read=(on-read_ != null)
        --validate-write=(validate_ != null)
        --value=value_
        --encrypted=(security_ >= SECURITY-ENCRYPTED)
        --authenticated=(security_ == SECURITY-AUTHENTICATED)
    handles[handle] = this
    descriptors_.do: | descriptor/Descriptor |
      descriptor.build_ session handle handles

  stringify -> string: return "Characteristic $uuid"

/** A descriptor in a $GattServer. */
class Descriptor:
  characteristic/Characteristic
  uuid/BleUuid
  value_/ByteArray := ?
  read_/bool
  write_/bool
  security_/int

  constructor .characteristic .uuid value/ByteArray --read/bool --write/bool --security/int:
    value_ = value.copy
    read_ = read
    write_ = write
    security_ = security

  /** The current value. */
  value -> ByteArray: return value_.copy

  /** Replaces the value for every central. */
  value= value/ByteArray -> none:
    if value.size > 512: throw "INVALID_ARGUMENT"
    value_ = value.copy
    characteristic.service.server.connections_.do: | link/PeripheralLink_ |
      handle := link.handle-of this
      if handle: catch: link.session.set-value handle value_

  build_ session/rpc.Session characteristic-handle/int handles/Map -> none:
    handle := session.add-descriptor characteristic-handle (uuid.to-byte-array --reversed)
        --read=read_
        --write=write_
        --value=value_
        --encrypted=(security_ >= SECURITY-ENCRYPTED)
        --authenticated=(security_ == SECURITY-AUTHENTICATED)
    handles[handle] = this

/**
The peripheral role: serves a $GattServer to centrals that connect.

$accept advertises and waits for the next central. Several centrals can be
  connected at once, up to the provider's peripheral session limit.
*/
class Peripheral:
  client_/rpc.Client
  server_/GattServer
  name_/string
  advertisement_/ByteArray := ?
  scan-response_/ByteArray := ?
  interval_/int
  handler-timeout_/Duration
  mtu_/int
  links_/List ::= []
  waiting_/rpc.Session? := null
  ended-signal_/monitor.Latch := monitor.Latch
  closed_/bool := false

  constructor.private_ .client_ .server_ --name/string --advertisement/Advertisement
      --scan-response/Advertisement? --interval/Duration --handler-timeout/Duration --mtu/int:
    if server_.peripheral_: throw "BLE_SERVER_IN_USE"
    name_ = name
    mtu_ = mtu
    advertisement_ = connectable-advertisement_ advertisement
    scan-response_ = scan-response ? (raw-advertisement_ scan-response) : #[]
    interval_ = advertising-interval_ interval
    handler-timeout_ = handler-timeout
    server_.peripheral_ = this

  /** The connected centrals. */
  connections -> List: return links_.map: | link/PeripheralLink_ | link.connection

  /**
  Changes what $accept advertises, also while an accept waits.
  */
  set-advertisement advertisement/Advertisement --scan-response/Advertisement?=null -> none:
    advertisement_ = connectable-advertisement_ advertisement
    scan-response_ = scan-response ? (raw-advertisement_ scan-response) : #[]
    waiting := waiting_
    if waiting: catch: waiting.update-advertising advertisement_ --scan-response=scan-response_

  /**
  Advertises until a central connects and returns its connection.

  This is where the application learns about new centrals; the end of each
    one is $Connection.wait-closed. Advertising runs only while an accept
    waits. When the provider already serves as many centrals as it can,
    this waits for one of them to leave first.
  */
  accept -> Connection:
    while true:
      if closed_: throw "BLE_CLOSED"
      session/rpc.Session? := null
      handles/Map? := null
      error := catch:
        built := build-session_
        session = built[0]
        handles = built[1]
        session.start advertisement_ --scan-response=scan-response_ --interval=interval_
      if error:
        if session: catch: session.close
        if error != "GATT_SERVICE_BUSY": throw error
        // Every slot serves a central; try again when one leaves.
        signal := ended-signal_
        catch: with-timeout --ms=1_000: signal.get
        continue
      peer/List? := null
      waiting_ = session
      try:
        error = catch: peer = session.peer
      finally:
        waiting_ = null
        if not peer: critical-do --no-respect-deadline: catch: session.close
      if error:
        // Advertising is bounded by the provider; start over.
        if error == "DEADLINE_EXCEEDED" or error == "GATT_REQUESTS_CLOSED": continue
        throw error
      return start-link_ session handles (Address peer[0] --type=peer[1])

  /** Stops accepting and disconnects every central. */
  close -> none:
    if closed_: return
    closed_ = true
    waiting := waiting_
    if waiting: catch: waiting.close
    links_.copy.do: | link/PeripheralLink_ | link.connection.close
    server_.peripheral_ = null

  /** Builds a provider session with the server's database; returns [session, handle map]. */
  build-session_ -> List:
    session := client_.configure --name=name_ --value-limit=512 --mtu-limit=mtu_
        --handler-timeout=handler-timeout_
        --attribute-limit=(max 64 server_.attribute-count_)
    handles := {:}
    error := catch:
      declarations := List server_.services_.size
      server_.services_.do: | service/Service | service.build_ session handles declarations
    if error:
      session.close
      throw error
    return [session, handles]

  start-link_ session/rpc.Session handles/Map peer/Peer -> Connection:
    link/PeripheralLink_? := null
    connection := Connection.peripheral_ session peer --on-release=::
      links_.remove link
      signal := ended-signal_
      ended-signal_ = monitor.Latch
      signal.set true
    link = PeripheralLink_ connection session handles
    links_.add link
    link.serve_
    return connection

/** One connected central: its provider session, handle map and request loop. */
class PeripheralLink_:
  connection/Connection
  session/rpc.Session
  handles_/Map
  worker_/Task? := null

  constructor .connection .session .handles_:

  handle-of element -> int?:
    handles_.do: | handle/int value | if value == element: return handle
    return null

  serve_ -> none:
    worker_ = task --background --name="BLE peripheral requests"::
      catch: loop_
      // The link ended or failed; the connection learns why from the provider.

  loop_ -> none:
    while true:
      request/rpc.Request := session.next
      element := handles_.get request.handle
      error := catch --trace=(: | exception _ | exception is not AttError):
        dispatch_ request element
      if request.is-pending:
        if error is AttError: catch: request.reject (error as AttError).code
        else if request.kind == api.WRITTEN: catch: request.accept
        else: catch: request.reject AttError.UNLIKELY-ERROR

  dispatch_ request/rpc.Request element -> none:
    if request.kind == api.READ:
      characteristic := element as Characteristic
      value/ByteArray := characteristic.on-read_.call connection
      request.reply value
      return
    if request.kind == api.VALIDATE-WRITE:
      characteristic := element as Characteristic
      characteristic.validate_.call connection request.value
      request.accept
      return
    // An applied write: it is the value for every central now.
    if element is Characteristic:
      characteristic := element as Characteristic
      characteristic.value_ = request.value
      characteristic.service.server.connections_.do: | other/PeripheralLink_ |
        if other != this:
          handle := other.handle-of characteristic
          if handle: catch: other.session.set-value handle request.value
      request.accept
      if characteristic.on-write_: characteristic.on-write_.call connection request.value
    else if element is Descriptor:
      (element as Descriptor).value_ = request.value
      request.accept
    else:
      request.accept

/**
Encodes connectable advertising data, adding the Flags field (LE General
  Discoverable, no BR/EDR) when $advertisement has none: scanners such as
  phones hide connectable advertisers without it.
*/
connectable-advertisement_ advertisement/Advertisement -> ByteArray:
  has-flags := advertisement.data-blocks.any: | block/DataBlock | block.is-flags
  if has-flags: return raw-advertisement_ advertisement
  raw := #[2, 1, 6] + advertisement.to-raw
  if raw.size > 31: throw "BLE_ADVERTISEMENT_TOO_LARGE"
  return raw

raw-advertisement_ advertisement/Advertisement -> ByteArray:
  raw := advertisement.to-raw
  if raw.size > 31: throw "BLE_ADVERTISEMENT_TOO_LARGE"
  return raw

advertising-interval_ interval/Duration -> int:
  units := interval.in-us / 625
  if not 32 <= units <= 16384: throw "INVALID_ARGUMENT"
  return units
