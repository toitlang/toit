// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ble show BleUuid Advertisement

import ..service.client as rpc
import .connection
import .peripheral
import .types

/**
The entry point: the device's BLE controller, reached through the BLE service.

On a device, a provider container owns the controller and every application
  opens its own adapter. On Linux, `ble.experimental.next.linux` installs a
  provider in the application's process.
*/
class Adapter:
  client_/rpc.Client
  provider-pid_/int?
  on-close_/Lambda? := null
  closed_/bool := false
  info_/List? := null

  /**
  Opens the adapter; throws when no BLE service provider runs.

  $provider-pid restricts the adapter to the provider with that process id.
  */
  constructor --provider-pid/int?=null:
    provider-pid_ = provider-pid
    client_ = rpc.Client --provider-pid=provider-pid
    client_.open

  /** Opens an adapter whose $close also runs $on-close (used by the Linux helper). */
  constructor.with-cleanup_ --on-close/Lambda:
    provider-pid_ = null
    client_ = rpc.Client
    client_.open
    on-close_ = on-close

  /** What the provider supports. */
  capabilities -> Capabilities:
    capabilities := client_.capabilities
    return Capabilities
        --scanning=capabilities.scanning
        --central=capabilities.gatt-central
        --peripheral=capabilities.gatt-peripheral
        --advertising=capabilities.advertising
        --max-value-size=capabilities.max-value-size
        --max-mtu=capabilities.max-mtu
        --max-sessions=capabilities.max-sessions

  adapter-info_ -> List:
    if not info_: info_ = client_.adapter-info
    return info_

  /** The controller's public identity address. */
  address -> Address: return Address adapter-info_[0]

  /** Whether the controller supports the LE 2M PHY. */
  supports-phy-2m -> bool: return adapter-info_[3]

  /** Whether $set-tx-power works on this controller. */
  supports-tx-power-control -> bool: return adapter-info_[1]

  /**
  The transmit power for advertising, scanning and new connections in dBm,
    or null when the controller does not say.
  */
  tx-power -> int?:
    info_ = null
    return adapter-info_[2]

  /**
  Sets the transmit power for advertising, scanning and new connections.

  Uses the closest level the controller has and returns it in dBm; the
    original ESP32 has -12 to +9 dBm, the ESP32-S3 -24 to +20 dBm. Throws
    BLE_UNSUPPORTED on controllers without transmit power control, such as
    Linux adapters. The setting stays with the provider while it runs.
  */
  set-tx-power dbm/int -> int:
    info_ = null
    return client_.set-tx-power dbm

  /**
  Scans and calls $block with every report.

  Stops after $duration, or when $block returns false. $active also asks
    advertisers for their scan responses. $services keeps only reports
    advertising one of the given service UUIDs. Without $duplicates, the
    controller reports each advertiser once.
  */
  scan --duration/Duration=(Duration --s=10) --active/bool=false --services/List?=null
      --duplicates/bool=false [block] -> none:
    filter := services and services.size == 1 ? ((services[0] as BleUuid).to-byte-array --reversed) : null
    client_.scan --duration=duration --active=active --filter-duplicates=(not duplicates)
        --service-uuid=filter: | raw/rpc.ScanReport |
      report := ScanReport raw
      if services and not filter and not (services.any: report.has-service it): continue.scan true
      (block.call report) != false

  /**
  Scans until an advertiser matches and returns its report, or null after
    $duration.

  Matches the $service UUID and the $name when given.
  */
  find --service/BleUuid?=null --name/string?=null --duration/Duration=(Duration --s=10)
      --active/bool=(name != null) -> ScanReport?:
    return find --service=service --name=name --duration=duration --active=active: true

  find --service/BleUuid?=null --name/string?=null --duration/Duration=(Duration --s=10)
      --active/bool=(name != null) [block] -> ScanReport?:
    found/ScanReport? := null
    scan --duration=duration --active=active --services=(service ? [service] : null): | report/ScanReport |
      if name and report.name != name: continue.scan true
      if not block.call report: continue.scan true
      found = report
      false
    return found

  /**
  Connects to the peripheral $peer (a $ScanReport's $ScanReport.peer, or an
    $Address).

  $mtu is the ATT MTU this side offers (23 to 517). $security is the level
    the link must reach before this returns; pairing and bonding follow the
    provider's policy, and a link that stays below the level is closed with
    BLE_INSUFFICIENT_SECURITY. $phy, when given, is requested once
    connected; by default the host moves to the 2M PHY when both sides have
    it.
  */
  connect peer/Peer --timeout/Duration=(Duration --s=10) --mtu/int=247
      --security/int=SECURITY-NONE --phy/int?=null -> Connection:
    if not 23 <= mtu <= 517: throw "INVALID_ARGUMENT"
    // The Toit host reaches every peer by its address.
    target := peer.address
    if not target: throw "INVALID_ARGUMENT"
    // Each connection is a session of its own service client: the provider
    // admits one session per client, and connections should not compete.
    client := rpc.Client --provider-pid=provider-pid_
    client.open
    raw/rpc.Connection? := null
    error := catch:
      raw = client.connect target.bytes --address-type=target.type --timeout=timeout --mtu-limit=mtu
          --require-encryption=(security >= SECURITY-ENCRYPTED)
          --require-authentication=(security == SECURITY-AUTHENTICATED)
    if error:
      client.close
      if error == "GATT_CENTRAL_SECURITY_REQUIRED": throw "BLE_INSUFFICIENT_SECURITY"
      throw error
    connection := Connection.central_ raw peer --mtu=raw.info[2] --client=client
    if phy:
      succeeded := false
      try:
        connection.request-phy phy
        succeeded = true
      finally:
        if not succeeded: connection.close
    return connection

  /**
  Connects to $peer, runs $block with the connection, and closes it on
    every exit.
  */
  with-connection peer/Peer --timeout/Duration=(Duration --s=10) --mtu/int=247
      --security/int=SECURITY-NONE --phy/int?=null [block] -> any:
    connection := connect peer --timeout=timeout --mtu=mtu --security=security --phy=phy
    try:
      return block.call connection
    finally:
      connection.close

  /**
  Serves $server to centrals; see $Peripheral.

  $advertisement (and the optional $scan-response) is advertised whenever
    $Peripheral.accept waits for a central, every $interval. $name is the GAP
    device name in the database. Handlers of the server get $handler-timeout
    to answer a central.
  */
  peripheral server/GattServer --advertisement/Advertisement --scan-response/Advertisement?=null
      --interval/Duration=(Duration --ms=100) --name/string="Toit"
      --handler-timeout/Duration=(Duration --s=1) -> Peripheral:
    return Peripheral.private_ client_ server
        --name=name
        --advertisement=advertisement
        --scan-response=scan-response
        --interval=interval
        --handler-timeout=handler-timeout

  /**
  Broadcasts $advertisement without accepting connections, until
    $Broadcast.stop.

  A $scan-response makes the advertising scannable.
  */
  advertise advertisement/Advertisement --scan-response/Advertisement?=null
      --interval/Duration=(Duration --ms=100) -> Broadcast:
    response := scan-response ? (raw-advertisement_ scan-response) : #[]
    advertising := client_.start-advertising (raw-advertisement_ advertisement)
        --scan-response=response
        --interval=(advertising-interval_ interval)
        --scannable=(not response.is-empty)
    return Broadcast advertising

  /** Closes the adapter and every resource opened through it. */
  close -> none:
    if closed_: return
    closed_ = true
    try:
      client_.close
    finally:
      if on-close_: on-close_.call

/** One advertiser seen by $Adapter.scan. */
class ScanReport:
  raw_/rpc.ScanReport
  advertisement_/Advertisement? := null

  constructor .raw_:

  /** The advertiser, to connect to or compare. */
  peer -> Peer: return Address raw_.address --type=raw_.address-type

  /** The advertiser's address, or null where the platform hides it (see $Peer). */
  address -> Address?: return peer.address

  /** The received signal strength in dBm, or null when the controller did not measure it. */
  rssi -> int?: return raw_.rssi

  /** The advertising data. */
  advertisement -> Advertisement:
    if not advertisement_: advertisement_ = raw_.advertisement
    return advertisement_

  /** The advertised name, or null. */
  name -> string?: return advertisement.name

  /** Whether the advertiser accepts connections; null for scan responses. */
  is-connectable -> bool?: return raw_.connectable

  /** Whether this report is a scan response rather than an advertisement. */
  is-scan-response -> bool: return raw_.scan-response == true

  /** Whether the advertisement lists the service $uuid. */
  has-service uuid/BleUuid -> bool:
    return advertisement.services.contains uuid

  stringify -> string:
    return "$peer rssi=$rssi$(name ? " name=$name" : "")"

/** Advertising without connections, from $Adapter.advertise. */
class Broadcast:
  advertising_/rpc.Advertising

  constructor .advertising_:

  /** Changes the advertised data. */
  update advertisement/Advertisement --scan-response/Advertisement?=null -> none:
    advertising_.update (raw-advertisement_ advertisement)
        --scan-response=(scan-response ? (raw-advertisement_ scan-response) : #[])

  /** Stops advertising. */
  stop -> none: advertising_.stop
