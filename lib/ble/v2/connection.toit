// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ..uuid show BleUuid
import monitor

import ..experimental.service.client as rpc
import .adapter show Adapter
import .peripheral show Peripheral GattServer
import .types

/**
Connections of the application API (`ble.v2`).

A $Connection is one link to a peer in either role: it comes from
  $Adapter.connect (this device is the central) or from $Peripheral.accept
  (a central connected to this device). It describes the link and reaches
  the peer's GATT database through $RemoteService, $RemoteCharacteristic
  (with $Subscription and $Values for notifications and indications) and
  $RemoteDescriptor.
*/

/**
A link to one peer, in either role.

A central-role connection comes from $Adapter.connect: this device connected
  to a peripheral and can use its GATT server through $discover-services. A
  peripheral-role connection comes from $Peripheral.accept: a central
  connected to this device's $GattServer.

The connection stays an object after the link ended: $wait-closed returns
  why, and the link's last state stays readable. $close releases it; do so
  for every connection, ended or not.
*/
class Connection:
  /**
  The device at the other end: its $Address on the Toit host (see $Peer
    for platforms that hide addresses).
  */
  peer/Peer
  /** This device's role on the link, $ROLE-CENTRAL or $ROLE-PERIPHERAL. */
  role/int

  central_/rpc.Connection? := null
  session_/rpc.Session? := null
  mtu_/int := 23
  ended_/monitor.Latch ::= monitor.Latch
  closing_/bool := false
  released_/bool := false
  watcher_/Task? := null
  last-info_/List? := null
  on-release_/Lambda? := null
  client_/rpc.Client? := null

  constructor.central_ .central_ .peer --mtu/int --client/rpc.Client:
    role = ROLE-CENTRAL
    mtu_ = mtu
    client_ = client
    start-watcher_

  constructor.peripheral_ .session_ .peer --on-release/Lambda:
    role = ROLE-PERIPHERAL
    on-release_ = on-release
    start-watcher_

  start-watcher_ -> none:
    watcher_ = task --background --name="BLE connection watcher"::
      reason/DisconnectReason? := null
      error := catch:
        last-info_ = backend_.link-info
        code := backend_.wait-disconnected
        reason = DisconnectReason code
      if error:
        reason = closing_
            ? DisconnectReason DisconnectReason.LOCAL-HOST
            : DisconnectReason null --message=error.stringify
      critical-do --no-respect-deadline:
        catch: if not released_: last-info_ = backend_.link-info
        if not ended_.has-value: ended_.set reason

  backend_ -> any:
    if released_: throw "BLE_CLOSED"
    return central_ or session_

  info_ -> List:
    if ended_.has-value or released_:
      if last-info_: return last-info_
      throw "BLE_CLOSED"
    return backend_.link-info

  /** Whether the link has ended. */
  is-closed -> bool: return ended_.has-value

  /**
  Waits for the link to end and returns why.

  Returns at once for a link that already ended.
  */
  wait-closed -> DisconnectReason: return ended_.get

  /** The negotiated ATT MTU: attribute values up to MTU - 3 bytes fit one packet. */
  mtu -> int:
    if session_ and not ended_.has-value and not released_: return session_.mtu
    return mtu_

  /** The PHYs in use. Every link starts on $PHY-1M. */
  phy -> Phy:
    info := info_
    return Phy info[1] info[2]

  /**
  Asks for the given PHY in both directions and returns the PHYs in use
    afterwards.

  The controllers settle on what both support, so the result may differ.
  */
  request-phy phy/int -> Phy: return request-phy --tx=phy --rx=phy

  /**
  Variant of $(request-phy phy).

  Asks for $tx in the transmit direction and $rx in the receive direction
    separately, for example the Coded PHY only where range is short.
  */
  request-phy --tx/int --rx/int -> Phy:
    if not PHY-1M <= tx <= PHY-CODED or not PHY-1M <= rx <= PHY-CODED: throw "INVALID_ARGUMENT"
    result := backend_.set-phy --tx=(1 << (tx - 1)) --rx=(1 << (rx - 1))
    return Phy result[0] result[1]

  /** The link-layer payload sizes in effect; 27 octets without Data Length Extension. */
  data-length -> DataLength:
    info := info_
    return DataLength info[3] info[4]

  /** The connection parameters in effect. */
  parameters -> ConnectionParameters:
    info := info_
    return ConnectionParameters info[5] info[6] info[7]

  /**
  Asks for new connection parameters and returns the ones the controllers
    applied.

  The interval is a range in which the central's controller picks; the
    supervision timeout must exceed (1 + $latency) * interval * 2. In the
    peripheral role this asks the central, which may refuse
    (L2CAP_PARAMETERS_REJECTED).
  */
  request-parameters --interval-min/Duration --interval-max/Duration=interval-min
      --latency/int=0 --supervision-timeout/Duration=(Duration --s=4) -> ConnectionParameters:
    result := backend_.update-parameters
        --interval-min=(interval-min.in-us / 1250)
        --interval-max=(interval-max.in-us / 1250)
        --latency=latency
        --supervision-timeout=(supervision-timeout.in-ms / 10)
    return ConnectionParameters result[0] result[1] result[2]

  /** The security the link has reached: $SECURITY-NONE, $SECURITY-ENCRYPTED or $SECURITY-AUTHENTICATED. */
  security -> int: return snapshot-level_ backend_.security

  /**
  Asks for at least $level ($SECURITY-ENCRYPTED or $SECURITY-AUTHENTICATED)
    and returns the level the link reached.

  As a peripheral, sends the central a Security Request and waits until
    pairing ended (at most 30 seconds); pairing follows the provider's
    policy, and a failed pairing ends the link. As a central, the link paired
    when it connected ($Adapter.connect's `--security`), so this only
    checks. Throws BLE_INSUFFICIENT_SECURITY when the link stays below
    $level, and BLE_UNSUPPORTED when the provider does not pair.
  */
  request-security level/int=SECURITY-ENCRYPTED -> int:
    if not SECURITY-ENCRYPTED <= level <= SECURITY-AUTHENTICATED: throw "INVALID_ARGUMENT"
    snapshot/rpc.SecuritySnapshot? := null
    error := catch --unwind=(: it != "GATT_SECURITY_UNSUPPORTED"):
      snapshot = backend_.request-security
    if error: throw "BLE_UNSUPPORTED"
    achieved := snapshot-level_ snapshot
    if achieved < level: throw "BLE_INSUFFICIENT_SECURITY"
    return achieved

  static snapshot-level_ snapshot/rpc.SecuritySnapshot -> int:
    if snapshot.authenticated: return SECURITY-AUTHENTICATED
    if snapshot.encrypted: return SECURITY-ENCRYPTED
    return SECURITY-NONE

  /** The controller's received signal strength for this link, in dBm. */
  rssi -> int: return backend_.rssi

  /** The controller's current transmit power on this link, in dBm. */
  tx-power -> int: return backend_.tx-power

  /**
  Sets this link's transmit power and returns the level used, in dBm (the
    supported level closest to $dbm); other links and advertising keep
    theirs ($Adapter.set-tx-power sets those). Throws BLE_UNSUPPORTED where
    the controller has no transmit power control ($Adapter.supports-tx-power-control).
  */
  set-tx-power dbm/int -> int: return backend_.set-tx-power dbm

  /**
  Discovers the peer's primary services, all or those in $uuids.

  In both roles: as a peripheral, this is the connected central's database
    (a phone's Current Time or Battery service, for example), reached over
    the same link while this device serves its own. The results belong to
    the peer's current database: after a Service Changed indication their
    operations throw and the application discovers again.
  */
  discover-services uuids/List?=null -> List:
    view := backend_.database
    records := view.discover-services
    result := []
    records.do: | record/rpc.ServiceRecord |
      uuid := BleUuid.from-reversed record.uuid
      if not uuids or (uuids.contains uuid): result.add (RemoteService this uuid record)
    return result

  /**
  Reads several characteristics in one request and returns their values.

  Uses Read Multiple Variable Length, and separate reads for a peer that
    does not support it. Values longer than MTU - 3 bytes in total are cut;
    read those one by one.
  */
  read-multiple characteristics/List -> List:
    if characteristics.size < 2:
      return characteristics.map: | characteristic/RemoteCharacteristic | characteristic.read
    handles := characteristics.map: | characteristic/RemoteCharacteristic | characteristic.record_.handle
    view := (characteristics[0] as RemoteCharacteristic).record_.view_
    catch --unwind=(: it is not AttError or it.code != AttError.REQUEST-NOT-SUPPORTED):
      return att_: view.read-multiple handles --variable
    return characteristics.map: | characteristic/RemoteCharacteristic | characteristic.read

  /** Discovers the service with the given $uuid; throws BLE_SERVICE_NOT_FOUND if the peer has none. */
  discover-service uuid/BleUuid -> RemoteService:
    services := discover-services [uuid]
    if services.is-empty: throw "BLE_SERVICE_NOT_FOUND"
    return services[0]

  /**
  Ends the link and waits until it has ended.

  Does nothing for a link that already ended. The connection stays readable
    until $close.
  */
  disconnect -> none:
    if ended_.has-value or released_: return
    closing_ = true
    if central_:
      // Ends the link and joins the provider's cleanup; the watcher sees the end.
      central_.disconnect
    else:
      session_.close
    with-timeout --ms=5_000: ended_.get

  /** Disconnects if needed and releases the connection. */
  close -> none:
    if released_: return
    critical-do --no-respect-deadline:
      catch: disconnect
      released_ = true
      if central_: catch: central_.close
      if session_: catch: session_.close
      if client_: catch: client_.close
      if watcher_: watcher_.cancel
      if not ended_.has-value: ended_.set (DisconnectReason DisconnectReason.LOCAL-HOST)
      if on-release_: catch: on-release_.call

  stringify -> string:
    return "Connection $(role == ROLE-CENTRAL ? "to" : "from") $peer"

/** A service on a peer, found by $Connection.discover-services. */
class RemoteService:
  connection/Connection
  uuid/BleUuid
  record_/rpc.ServiceRecord

  constructor .connection .uuid .record_:

  /** Discovers this service's characteristics, all or those in $uuids. */
  discover-characteristics uuids/List?=null -> List:
    result := []
    record_.characteristics.do: | record/rpc.CharacteristicRecord |
      found := BleUuid.from-reversed record.uuid
      if not uuids or (uuids.contains found): result.add (RemoteCharacteristic this found record)
    return result

  /** Discovers the services this service includes. */
  discover-included-services -> List:
    return att_: record_.included-services.map: | record/rpc.ServiceRecord |
      RemoteService connection (BleUuid.from-reversed record.uuid) record

  /**
  Reads every characteristic of this service with the given $uuid in one
    procedure (Read Using Characteristic UUID) and returns their values.

  Each value is at most MTU - 4 bytes.
  */
  read-by-uuid uuid/BleUuid -> List:
    pairs := att_: record_.read-by-uuid (uuid.to-byte-array --reversed)
    return pairs.map: | pair/List | pair[1]

  /** Discovers the characteristic with the given $uuid; throws BLE_CHARACTERISTIC_NOT_FOUND if there is none. */
  characteristic uuid/BleUuid -> RemoteCharacteristic:
    found := discover-characteristics [uuid]
    if found.is-empty: throw "BLE_CHARACTERISTIC_NOT_FOUND"
    return found[0]

  stringify -> string: return "RemoteService $uuid"

/** A characteristic on a peer. */
class RemoteCharacteristic:
  static PROPERTY-BROADCAST ::= 0x01
  static PROPERTY-READ ::= 0x02
  static PROPERTY-WRITE-WITHOUT-RESPONSE ::= 0x04
  static PROPERTY-WRITE ::= 0x08
  static PROPERTY-NOTIFY ::= 0x10
  static PROPERTY-INDICATE ::= 0x20

  service/RemoteService
  uuid/BleUuid
  record_/rpc.CharacteristicRecord

  constructor .service .uuid .record_:

  /** The characteristic's property bits (the PROPERTY- constants). */
  properties -> int: return record_.properties

  /** The value's attribute handle in the peer's database. */
  handle -> int: return record_.handle

  can-read -> bool: return properties & PROPERTY-READ != 0
  can-write -> bool: return properties & PROPERTY-WRITE != 0
  can-write-without-response -> bool: return properties & PROPERTY-WRITE-WITHOUT-RESPONSE != 0
  can-notify -> bool: return properties & PROPERTY-NOTIFY != 0
  can-indicate -> bool: return properties & PROPERTY-INDICATE != 0

  /** Reads the value; values longer than the MTU are read in parts. Throws $AttError on refusal. */
  read -> ByteArray: return att_: record_.read

  /**
  Writes the value and waits for the peer's response.

  With `--no-response` sends a Write Command instead: completion then only
    means the controller took it, and the value must fit in MTU - 3 bytes.
  */
  write value/ByteArray --response/bool=true -> none:
    att_:
      if not response: record_.write-command value
      else: record_.write value

  /**
  Subscribes for the scope of $block, which receives a $Values stream, and
    returns the block's result.

  Uses notifications when the characteristic has them, else indications
    (or indications when $indications is true). Leaving the block
    unsubscribes. At most $queue-limit values wait for the block (1 to 32);
    more end the subscription with ATT_NOTIFICATION_OVERFLOW.
  */
  subscribe --indications/bool?=null --queue-limit/int=8 [block] -> any:
    use-indications := indications == null ? (not can-notify and can-indicate) : indications
    return att_:
      record_.subscribe --indications=use-indications --queue-limit=queue-limit: | stream/rpc.Subscription |
        block.call (Values stream)

  /**
  Variant of $(subscribe --indications --queue-limit [block]).

  Returns a $Subscription that lasts until $Subscription.close instead of
    the scope of a block, for values received from a field or by several
    tasks in turn. The subscription is active when this returns;
    $Subscription.close unsubscribes and waits until the peer was told. A
    task in the background holds it, so close it before dropping it.
  */
  subscribe --indications/bool?=null --queue-limit/int=8 -> Subscription:
    return Subscription.start_ this --indications=indications --queue-limit=queue-limit

  /** Discovers this characteristic's descriptors. */
  discover-descriptors -> List:
    return att_: record_.descriptors.map: | record/rpc.DescriptorRecord |
      RemoteDescriptor this (BleUuid.from-reversed record.uuid) record

  stringify -> string: return "RemoteCharacteristic $uuid"

/**
A subscription that lasts until $close; see
  $(RemoteCharacteristic.subscribe --indications --queue-limit).
*/
class Subscription:
  characteristic/RemoteCharacteristic
  values_/Values? := null
  stop_/monitor.Latch ::= monitor.Latch
  ended_/monitor.Latch ::= monitor.Latch
  closed_/bool := false

  constructor.start_ .characteristic --indications/bool? --queue-limit/int:
    ready := monitor.Latch
    task --background::
      error := catch:
        characteristic.subscribe --indications=indications --queue-limit=queue-limit: | values/Values |
          ready.set values
          stop_.get
      if not ready.has-value: ready.set error
      critical-do --no-respect-deadline: ended_.set error
    started := ready.get
    if started is not Values: throw started
    values_ = started

  /**
  Waits for the next value.

  Throws when the subscription ended: BLE_CLOSED after $close, otherwise
    the reason it ended (the link closed, the queue overflowed).
  */
  receive -> ByteArray:
    if closed_: throw "BLE_CLOSED"
    return values_.receive

  /** Whether the subscription ended, by $close or otherwise. */
  is-closed -> bool: return closed_ or ended_.has-value

  /** Unsubscribes, and waits until the peer was told or the link ended. */
  close -> none:
    if closed_: return
    closed_ = true
    stop_.set true
    ended_.get

/** Values arriving on a subscription. */
class Values:
  stream_/rpc.Subscription

  constructor .stream_:

  /** Waits for the next value. */
  receive -> ByteArray: return att_: stream_.receive

/** A descriptor on a peer. */
class RemoteDescriptor:
  characteristic/RemoteCharacteristic
  uuid/BleUuid
  record_/rpc.DescriptorRecord

  constructor .characteristic .uuid .record_:

  /** The descriptor's attribute handle in the peer's database. */
  handle -> int: return record_.handle

  read -> ByteArray: return att_: record_.read
  write value/ByteArray -> none: att_: record_.write value

  stringify -> string: return "RemoteDescriptor $uuid"

/** Runs $block, turning the service client's ATT errors into $AttError. */
att_ [block] -> any:
  error := catch --unwind=(: it is not rpc.AttributeError):
    return block.call
  throw (AttError error.code --handle=error.handle --request=error.request)
