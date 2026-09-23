// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import system.services
import ble show Advertisement

import .api as api
import io

/**
Opens the experimental BLE request service without importing host code.

Outgoing byte arrays are snapshotted before RPC, preserving caller-owned arrays
  even when their backing storage is external. RPC may return external arrays;
  ownership does not imply that their bytes are on the compacting heap.
*/
class Client extends services.ServiceClient:
  /**
  Restricts discovery to a trusted runtime process when $provider-pid is set.

  Obtain the PID from trusted launch code, not discovery metadata. A restarted
    provider requires a new client with its new PID. Null preserves ordinary
    service discovery; a selected but absent provider never falls back.
  */
  constructor --provider-pid/int?=null:
    super api.SELECTOR --provider-pid=provider-pid

  /** Queries configured software support without reserving the controller. */
  capabilities -> Capabilities:
    return Capabilities (invoke_ api.CAPABILITIES null)

  /**
  Advertises without accepting connections for the lifetime of $body.

  Uses the provider's address policy (public by default). $interval uses 625 microsecond units,
    from 32 through 16384. Both payloads are limited to 31 bytes. Scan responses
    require $scannable. The body receives the $Advertising handle after enable
    succeeds. It may update the payload or stop early. All exits stop advertising
    and release the exclusive controller session; a retained handle is closed
    when the scope ends.
    Cleanup errors propagate on normal exit; a failing or canceled body retains
    its original failure while cleanup is still attempted.
  */
  with-advertising data/ByteArray --scan-response/ByteArray=#[]
      --interval/int=160 --scannable/bool=false [body]:
    session := start-advertising data --scan-response=scan-response
        --interval=interval
        --scannable=scannable
    try:
      return body.call session
    finally: | is-exception _ |
      critical-do --no-respect-deadline:
        error := catch: session.stop
        if error and not is-exception: throw error

  /**
  Starts non-connectable advertising and returns its explicit lifetime handle.

  Uses the same parameters and ownership rules as $with-advertising. Returns
    after the controller enables advertising. Call $Advertising.stop when done,
    before starting a replacement with different parameters. Prefer
    $with-advertising when a scoped block can express the lifetime.
    Closing this client also releases its advertising resource.
  */
  start-advertising data/ByteArray --scan-response/ByteArray=#[]
      --interval/int=160 --scannable/bool=false -> Advertising:
    session := Advertising this (open_ api.OPEN-ADVERTISING [(copy-bounded_ data 31), (copy-bounded_ scan-response 31), interval, scannable])
    ready := false
    try:
      session.ready_
      ready = true
      return session
    finally:
      if not ready: session.stop

  /**
  Connects one central-role session; addresses use HCI byte order.

  $require-encryption and $require-authentication check the provider's achieved
    security before returning. Authentication also requires encryption. Failure
    closes the connection and throws GATT_CENTRAL_SECURITY_REQUIRED. These flags
    do not enable pairing or change the provider's security policy; configure
    that policy in trusted provider code. Defaults impose no additional check.
    Disconnect/cleanup failures can propagate instead of the requirement error.
  */
  connect address/ByteArray --address-type/int=0 --timeout/Duration=(Duration --s=30) --mtu-limit/int=23
      --require-encryption/bool=false --require-authentication/bool=false -> Connection:
    result := Connection this (open_ api.CONNECT [(copy-bounded_ address 6), address-type, timeout.in-us, mtu-limit])
    succeeded := false
    try:
      result.info
      if require-encryption or require-authentication:
        state := result.security
        if not state.encrypted or (require-authentication and not state.authenticated):
          critical-do --no-respect-deadline: result.disconnect
          throw "GATT_CENTRAL_SECURITY_REQUIRED"
      succeeded = true
    finally:
      if not succeeded:
        critical-do --no-respect-deadline: result.close
    return result

  /**
  Runs a scoped connection block and waits for cleanup on exit.

  The security requirements have the same meaning as on $connect; an
    insufficiently secured connection never enters $body.
    A failed or canceled body keeps its original failure if disconnect also
    fails. On normal exit, disconnect errors propagate.
  */
  with-connection address/ByteArray --address-type/int=0 --timeout/Duration=(Duration --s=30) --mtu-limit/int=23
      --require-encryption/bool=false --require-authentication/bool=false [body]:
    connection := connect address --address-type=address-type --timeout=timeout --mtu-limit=mtu-limit
        --require-encryption=require-encryption
        --require-authentication=require-authentication
    try:
      return body.call connection
    finally: | is-exception _ |
      critical-do --no-respect-deadline:
        error := catch: connection.disconnect
        if error and not is-exception: throw error

  /**
  Scans through a scoped block until it returns false or the duration expires.

  $continuous scans until stopped or cancelled and ignores $duration. Finite durations remain
    limited by the provider's maximum scan duration.

  The provider filters optional little-endian service UUIDs and bounds both HCI
    events and report delivery to 32 queued entries each. The result contains
    dropped HCI events, dropped individual reports, and reports left unread when
    stopped. These counts have different units and must not be added together.
    Exceptions and cancellation close the scan resource. No protocol host is
    imported by this client.

  $limited-only requires the Limited Discoverable bit in each report's own Flags
    AD field. Reports without Flags, including scan responses, are omitted;
    no previous advertisement is used to infer a scan response's flags.
  */
  scan --duration/Duration=(Duration --s=10) --continuous/bool=false --active/bool=false
      --interval/int=16 --window/int=16 --filter-duplicates/bool=true
      --service-uuid/ByteArray?=null --limited-only/bool=false [report] -> List:
    scan := Scan_ this (open_ api.OPEN-SCAN [continuous ? null : duration.in-us, active, interval, window, filter-duplicates, service-uuid and (copy-bounded_ service-uuid 16), limited-only])
    try:
      while true:
        value := scan.next
        if not value or not (report.call value): break
      return scan.stop
    finally:
      scan.close

  /** Opens the provider's configured peripheral session. */
  session -> Session:
    return Session this (open_ api.OPEN null)

  /**
  Opens a bounded database builder without acquiring the controller yet.

  $value-limit is at most 512 bytes and $mtu-limit is 23 through 517. The MTU
    remains 23 until the peer exchanges it. The value bound also limits RPC
    handler records and replies; larger retained values can use long reads.
    $handler-timeout sets the per-handler budget described by
    $Session.set-handler-timeout; it defaults to one second.
  */
  configure --name/string="Toit" --value-limit/int=20 --mtu-limit/int=23
      --handler-timeout/Duration=(Duration --s=1) -> Session:
    if not 1 <= handler-timeout.in-us <= 10_000_000: throw "INVALID_ARGUMENT"
    result := value-limit == 20 and mtu-limit == 23
        ? (Session this (open_ api.OPEN-BUILDER name))
        : (Session this (open_ api.OPEN-BOUNDED-BUILDER [name, value-limit, mtu-limit]))
    succeeded := false
    try:
      if handler-timeout.in-us != 1_000_000: result.set-handler-timeout handler-timeout
      succeeded = true
      return result
    finally:
      if not succeeded: result.close

  call_ index/int arguments/List -> any: return invoke_ index arguments

  /**
  Opens a provider resource atomically and returns its handle.

  The provider admits and creates a resource without waiting, but an open
    whose reply is lost to the caller's cancellation would leak that resource
    until this client closes. The open therefore runs to completion; a
    cancelled caller observes its cancellation at the next wait and releases
    the proxy in its cleanup (docs/ble/design.md, rules 1 and 5).
  */
  open_ index/int arguments/any -> int:
    handle/int? := null
    critical-do --no-respect-deadline: handle = invoke_ index arguments
    return handle

  next_ handle/int -> List: return invoke_ api.NEXT [handle]

  wait-closed_ handle/int -> string: return invoke_ api.WAIT-CLOSED [handle]

  reply_ handle/int token/int error/int value/ByteArray -> none:
    invoke_ api.REPLY [handle, token, error, (copy-bounded_ value 512)]

/**
Configured provider support, independent of current hardware availability.

Security policy and authentication are not implied by these operation flags.
  A controller operation may still fail because hardware is busy or unavailable.
*/
class Capabilities:
  flags_/int
  /** Maximum finite scan duration; continuous scanning is reported separately. */
  max-scan-duration/Duration
  max-value-size/int
  max-mtu/int
  max-sessions/int

  constructor values/List:
    if values.size != 5: throw "BLE_INVALID_CAPABILITIES"
    flags_ = values[0]
    max-scan-duration = Duration --us=values[1]
    max-value-size = values[2]
    max-mtu = values[3]
    max-sessions = values[4]

  scanning -> bool: return flags_ & api.CAP-SCAN != 0
  continuous-scanning -> bool: return flags_ & api.CAP-CONTINUOUS-SCAN != 0
  advertising -> bool: return flags_ & api.CAP-ADVERTISING != 0
  gatt-peripheral -> bool: return flags_ & api.CAP-GATT-PERIPHERAL != 0
  gatt-central -> bool: return flags_ & api.CAP-GATT-CENTRAL != 0

  /** Reports opt-in central/peripheral sharing; controller support is checked on open. */
  mixed-roles -> bool: return flags_ & api.CAP-MIXED-ROLES != 0

/** A peer ATT error retaining the request opcode, handle and protocol code. */
class AttributeError:
  request/int
  handle/int
  code/int

  constructor .request .handle .code:
  stringify -> string: return "ATT_ERROR request=$request handle=$handle code=$code"

/**
A connection-scoped GATT client; all protocol operations run in the provider.

Discovery returns owned lists: services [start,end,uuid], characteristics
  [declaration,handle,properties,uuid,end], descriptors [handle,uuid]. UUIDs use
  wire order. These are observations for this connection, not a persistent cache.
  Numeric handles/ranges must be rediscovered after reconnect or database change.
  Use a DatabaseView inside with-service-changed for revision-checked access.
  Operations after local closure throw GATT_CONNECTION_CLOSED; disconnect remains
  idempotent.
*/
class Connection extends services.ServiceResourceProxy:
  connection_/Client

  constructor .connection_ handle/int:
    super connection_ handle

  handle_ -> int:
    if is-closed: throw "GATT_CONNECTION_CLOSED"
    return super

  /** Returns peer address, address type and negotiated MTU. */
  info -> List: return connection_.call_ api.CENTRAL-READY [handle_]

  /** Returns a fresh observation of this link's achieved security. */
  security -> SecuritySnapshot: return SecuritySnapshot (operation_ api.SECURITY [])

  read handle/int -> ByteArray: return operation_ api.CENTRAL-READ [handle]
  write handle/int value/ByteArray -> none: operation_ api.CENTRAL-WRITE [handle, (copy-bounded_ value 512)]
  /** Submits a Write Command; completion does not acknowledge peer receipt. */
  write-command handle/int value/ByteArray -> none: operation_ api.CENTRAL-WRITE-COMMAND [handle, (copy-bounded_ value 512)]
  services -> List: return operation_ api.CENTRAL-SERVICES []
  characteristics start/int end/int -> List: return operation_ api.CENTRAL-CHARACTERISTICS [start, end]
  descriptors handle/int end/int -> List: return operation_ api.CENTRAL-DESCRIPTORS [handle, end]

  /** Captures this connection's current database revision for checked access. */
  database -> DatabaseView: return DatabaseView this (operation_ api.CENTRAL-REVISION [])

  /**
  Monitors Service Changed while running the scoped block.

  Discover through a fresh $database view inside the block. A change invalidates
    existing views; obtain a new view and rediscover before using new handles.
    Entering and leaving this scope also invalidates previous views. Missing
    Service Changed is an error, not a promise that the peer's layout is fixed.
    Cleanup errors propagate only when the body is not already failing or canceled.
  */
  with-service-changed [body]:
    token := operation_ api.CENTRAL-MONITOR []
    try:
      operation_ api.CENTRAL-SUBSCRIPTION-READY [token]
      return body.call
    finally: | is-exception _ |
      critical-do --no-respect-deadline:
        error := catch:
          if not is-closed: operation_ api.CENTRAL-UNSUBSCRIBE [token]
        if error and not is-exception: throw error

  /**
  Enables a scoped notification or indication subscription.

  The provider queues at most $queue-limit values (1–32, default 8), with a
    shared 32-value limit across at most eight subscriptions. Overflow throws
    ATT_NOTIFICATION_OVERFLOW instead of silently dropping data. Indications
    are confirmed by the provider when received, before application processing.
    Scope exit disables the CCCD; a failed disable terminates the connection.
    Cleanup errors propagate only when the body is not already failing or canceled.
  */
  subscribe handle/int --cccd/int --indications/bool=false --queue-limit/int=8 [body]:
    return subscribe_ handle cccd indications queue-limit null body

  subscribe_ handle/int cccd/int indications/bool limit/int revision/int? [body]:
    arguments := [handle, cccd, indications, limit]
    token := revision == null
        ? (operation_ api.CENTRAL-SUBSCRIBE arguments)
        : (operation_ api.CENTRAL-CHECKED [revision, api.CENTRAL-SUBSCRIBE, arguments])
    stream := Subscription this token
    try:
      operation_ api.CENTRAL-SUBSCRIPTION-READY [token]
      return body.call stream
    finally: | is-exception _ |
      critical-do --no-respect-deadline:
        error := catch:
          if not is-closed: operation_ api.CENTRAL-UNSUBSCRIBE [token]
        if error and not is-exception: throw error

  /** Ends the connection and waits for protocol cleanup before releasing ownership. */
  disconnect -> none:
    if is-closed: return
    try:
      connection_.call_ api.CENTRAL-STOP [handle_]
    finally:
      close

  operation_ index/int arguments/List:
    result := connection_.call_ index ([handle_] + arguments)
    if result[0]: return result[1]
    throw (AttributeError result[1] result[2] result[3])

/** Receives owned values while its connection's subscription block is active. */
class Subscription:
  connection_/Connection
  token_/int
  constructor .connection_ .token_:
  /**
  Receives the next owned value.

  If this call fails, the provider may already have consumed the value. Leave
    the subscription scope instead of retrying the receive; scope exit disables
    the subscription. Indication confirmation does not acknowledge delivery to
    this application.
  */
  receive -> ByteArray: return connection_.operation_ api.CENTRAL-SUBSCRIPTION-NEXT [token_]

/**
An immutable connection/revision binding for discovery and value operations.

Handles discovered through this view belong to its revision. Reuse this view
  for dependent discovery, reads and writes; do not carry old numeric handles
  into a newly captured view. Operations reject database changes, including
  changes during requests. A rejected write may already have reached the peer
  and must not be replayed automatically. This is not a persistent cache.
*/
class DatabaseView:
  connection_/Connection
  revision_/int
  constructor .connection_ .revision_:
  /** Enables a scoped subscription only while this database revision is current. */
  subscribe handle/int --cccd/int --indications/bool=false --queue-limit/int=8 [body]:
    return connection_.subscribe_ handle cccd indications queue-limit revision_ body
  services -> List: return call_ api.CENTRAL-SERVICES []
  /** Discovers typed service records bound to this view's revision. */
  discover-services -> List:
    return services.map: ServiceRecord this it
  characteristics start/int end/int -> List: return call_ api.CENTRAL-CHARACTERISTICS [start, end]
  descriptors handle/int end/int -> List: return call_ api.CENTRAL-DESCRIPTORS [handle, end]
  read handle/int -> ByteArray: return call_ api.CENTRAL-READ [handle]
  write handle/int value/ByteArray -> none: call_ api.CENTRAL-WRITE [handle, (copy-bounded_ value 512)]
  /** Submits a revision-checked Write Command, bounded by MTU minus three. */
  write-command handle/int value/ByteArray -> none: call_ api.CENTRAL-WRITE-COMMAND [handle, (copy-bounded_ value 512)]
  call_ index/int arguments/List:
    return connection_.operation_ api.CENTRAL-CHECKED [revision_, index, arguments]

/** A discovered service retaining its owning connection and database revision. */
class ServiceRecord:
  view_/DatabaseView
  uuid_/ByteArray
  start/int
  end/int
  constructor .view_ values/List:
    start = values[0]
    end = values[1]
    uuid_ = values[2].copy
  uuid -> ByteArray: return uuid_.copy
  characteristics -> List:
    return (view_.characteristics start end).map: CharacteristicRecord view_ it

/** A discovered characteristic; operations retain its original revision. */
class CharacteristicRecord:
  view_/DatabaseView
  uuid_/ByteArray
  declaration/int
  handle/int
  properties/int
  end/int
  constructor .view_ values/List:
    declaration = values[0]
    handle = values[1]
    properties = values[2]
    uuid_ = values[3].copy
    end = values[4]
  uuid -> ByteArray: return uuid_.copy
  read -> ByteArray: return view_.read handle
  write value/ByteArray -> none: view_.write handle value
  /** Submits an unacknowledged command when the characteristic permits it. */
  write-command value/ByteArray -> none:
    if properties & 0x04 == 0: throw "GATT_NOT_COMMAND_WRITABLE"
    view_.write-command handle value
  descriptors -> List:
    return (view_.descriptors handle end).map: DescriptorRecord view_ it

  /** Discovers the CCCD and enables a revision-checked scoped subscription. */
  subscribe --indications/bool=false --queue-limit/int=8 [body]:
    if properties & (indications ? 0x20 : 0x10) == 0:
      throw (indications ? "GATT_NOT_INDICATABLE" : "GATT_NOT_NOTIFIABLE")
    matches := descriptors.filter: | descriptor/DescriptorRecord | descriptor.is-cccd_
    if matches.size != 1: throw "GATT_INVALID_CCCD"
    return view_.subscribe handle --cccd=matches[0].handle --indications=indications --queue-limit=queue-limit body

/** A discovered descriptor whose reads and writes use its original revision. */
class DescriptorRecord:
  view_/DatabaseView
  uuid_/ByteArray
  handle/int
  constructor .view_ values/List:
    handle = values[0]
    uuid_ = values[1].copy
  uuid -> ByteArray: return uuid_.copy
  read -> ByteArray: return view_.read handle
  write value/ByteArray -> none: view_.write handle value
  is-cccd_ -> bool:
    return uuid_ == #[2, 0x29] or uuid_ == #[0xfb, 0x34, 0x9b, 0x5f, 0x80, 0, 0, 0x80, 0, 0x10, 0, 0, 2, 0x29, 0, 0]

/**
An owned legacy scan report; payload bytes are opaque advertising data.

Convenience properties decode Core 6.3, Vol 4 Part E, section 7.7.65.2.
  Reserved event types remain available as $event-type and yield null properties.
  A scan response does not identify its originating advertisement's type, so its
  connectability and scannability are unknown here. No prior report is inferred.
*/
class ScanReport:
  event-type/int
  address-type/int
  address/ByteArray
  data/ByteArray
  rssi/int?

  constructor values/List:
    event-type = values[0]
    address-type = values[1]
    address = values[2]
    data = values[3]
    rssi = values[4]

  /**
  Decodes this report's advertisement data into an independently owned value.

  Uses the SDK's $Advertisement representation, including raw blocks for
    malformed trailing data. Typed queries retain that representation's
    validation behavior. Each access decodes the current $data; no cached value
    is retained and no previous advertisement or scan response is merged.
  */
  advertisement -> Advertisement:
    return Advertisement.raw data.copy

  /** Reports whether this advertisement accepts connection requests. */
  connectable -> bool?:
    if not 0 <= event-type <= 3: return null
    return event-type == 0 or event-type == 1

  /** Reports whether this advertisement accepts scan requests. */
  scannable -> bool?:
    if not 0 <= event-type <= 3: return null
    return event-type == 0 or event-type == 2

  /** Reports whether this is a scan response rather than an advertisement. */
  scan-response -> bool?:
    if not 0 <= event-type <= 4: return null
    return event-type == 4

/** Owns one advertising session; $stop waits for cleanup and releases the handle. */
class Advertising extends services.ServiceResourceProxy:
  connection_/Client

  constructor .connection_ handle/int:
    super connection_ handle

  ready_ -> none: connection_.call_ api.ADVERTISING-READY [handle_]

  /**
  Updates advertising and scan-response data without reopening the controller.

  Copies both inputs, limited to31 bytes each. A nonempty scan response requires
    a scannable session. Interval, mode and address policy remain those selected
    at start. Returns after the controller accepts both commands; it does not
    acknowledge reception by a peer. The two fields may change at different
    advertising events and are not an atomic over-the-air pair.

  Only one update may be outstanding per session. Cancellation or a controller
    error stops the session because part of the update may already have applied.
    Close with $stop after an update failure; validation or busy errors before
    submission leave the existing session usable.
  */
  update data/ByteArray --scan-response/ByteArray=#[] -> none:
    if is-closed: throw "BLE_ADVERTISING_CLOSED"
    arguments := [handle_, (copy-bounded_ data 31), (copy-bounded_ scan-response 31)]
    completed := false
    try:
      error := catch: connection_.call_ api.ADVERTISING-UPDATE arguments
      if error:
        // These provider errors precede publication of this request.
        completed = error == "INVALID_ARGUMENT" or error == "BLE_ADVERTISING_UPDATE_BUSY"
        throw error
      completed = true
    finally:
      if not completed:
        // RPC cancellation alone does not retract a submitted update. Preserve
        // the primary failure while explicitly stopping this session.
        critical-do --no-respect-deadline: catch: stop

  /**
  Stops advertising and waits for bounded provider cleanup before releasing ownership.

  Repeated calls do nothing. A cleanup failure throws and may leave the provider
    unavailable; releasing the local handle does not prove controller recovery.
  */
  stop -> none:
    if is-closed: return
    critical-do --no-respect-deadline:
      try:
        connection_.call_ api.ADVERTISING-STOP [handle_]
      finally:
        close

class Scan_ extends services.ServiceResourceProxy:
  connection_/Client

  constructor .connection_ handle/int:
    super connection_ handle

  next -> ScanReport?:
    values := connection_.call_ api.SCAN-NEXT [handle_]
    return values and (ScanReport values)

  stop -> List: return connection_.call_ api.SCAN-STOP [handle_]

/**
Runs application blocks locally while the provider owns ATT and HCI.

Operations after local closure throw GATT_REQUESTS_CLOSED. The serving loop
  closes this handle on exit; inspect $termination-reason for its observed cause.
*/
class Session extends services.ServiceResourceProxy:
  /**
  Sets the per-handler budget before start seals the session.

  The default is one second; the supported range is one microsecond through
    ten seconds. Read, write-validation and accepted-write hooks each receive
    this budget, including RPC delivery time. This is not the ATT transaction
    timeout or a guarantee that the peer waits as long. Expired replies remain
    invalid. Accepted writes are not rolled back when their written hook fails.
    The provider also bounds all serving work for one ATT PDU to ten seconds;
    several callbacks share that aggregate bound. Exceeding it closes the link.
  */
  set-handler-timeout timeout/Duration -> none:
    connection_.call_ api.SET-HANDLER-TIMEOUT [handle_, timeout.in-us]

  connection_/Client
  serving_/bool := false
  serving-task_/Task? := null
  termination-reason_/string? := null

  /**
  Returns the closure reason observed while serving, or null if none was observed.

  The value survives local resource cleanup. A supervisor can inspect it after
    joining a serving worker that was canceled during a callback. This does not
    join that worker or promise controller cleanup is complete. Local closure
    or an application exception may leave it null. Provider loss may report an
    RPC error instead of a controller-specific cause.
  */
  termination-reason -> string?: return termination-reason_

  constructor .connection_ handle/int:
    super connection_ handle

  handle_ -> int:
    if is-closed: throw "GATT_REQUESTS_CLOSED"
    return super

  /** Adds a primary service before advertising starts; UUIDs use wire order. */
  add-service uuid/ByteArray -> int:
    return connection_.call_ api.ADD-SERVICE [handle_, (copy-bounded_ uuid 16)]

  /**
  Adds a bounded descriptor to the latest characteristic before start.

  A writable User Description also adds required Extended Properties metadata.
    Use the returned handle; do not assume consecutive application handles.
    User Description values must be valid UTF-8, including peer writes.
  */
  add-descriptor characteristic/int uuid/ByteArray --read/bool=true --write/bool=false
      --value/ByteArray=#[] --encrypted/bool=false --authenticated/bool=false -> int:
    flags := (read ? 1 : 0) | (write ? 2 : 0) | (encrypted ? 4 : 0) | (authenticated ? 8 : 0)
    return connection_.call_ api.ADD-DESCRIPTOR [handle_, characteristic, (copy-bounded_ uuid 16), flags, (copy-bounded_ value 512)]

  /**
  Adds a characteristic and returns its provider-assigned value handle.

  $encrypted and $authenticated protect peer access to the value and its CCCD.
    The provider owns pairing policy and confirmation; these flags cannot grant
    security or enable pairing. Without provider pairing support, access fails
    closed. Local value/set-value operations remain owner operations.
  */
  add-characteristic uuid/ByteArray --read/bool=false --write/bool=false
      --write-command/bool=false
      --notify/bool=false --indicate/bool=false --dynamic-read/bool=false --validate-write/bool=false
      --value/ByteArray=#[] --encrypted/bool=false --authenticated/bool=false -> int:
    flags := (read ? 1 : 0) | (write ? 2 : 0) | (notify ? 4 : 0) |
        (dynamic-read ? 8 : 0) | (validate-write ? 16 : 0)
    flags |= (encrypted ? 32 : 0) | (authenticated ? 64 : 0) | (indicate ? 128 : 0)
    if write-command: flags |= 256
    return connection_.call_ api.ADD-CHARACTERISTIC [handle_, (copy-bounded_ uuid 16), flags, (copy-bounded_ value 512)]

  /**
  Freezes configuration and starts accepting one peripheral connection.

  $interval uses 625 microsecond units, from 32 through 16384 (default 160).
    It controls advertising before connection, not the connection interval.
    Invalid parameters leave the builder available for correction.
  */
  start advertisement/ByteArray --scan-response/ByteArray=#[] --interval/int=160 -> none:
    connection_.call_ api.START [handle_, (copy-bounded_ advertisement 31), (copy-bounded_ scan-response 31), interval]

  /**
  Updates connectable advertising while this session waits for its peer.

  Copies both payloads, each limited to 31 bytes. The interval and address remain
    unchanged. Returns true after both controller commands complete, or false
    if advertising ends before completion. Connection creation may race either
    command; false does not discard a winning connection. The fields are not an
    atomic over-the-air pair and success does not acknowledge peer reception.

  Call after $start; an update submitted during setup waits for enablement.
    Only one update may be outstanding. Validation and busy errors leave the
    session usable. Cancellation or an uncertain RPC result closes the session.
  */
  update-advertising data/ByteArray --scan-response/ByteArray=#[] -> bool:
    if is-closed: throw "GATT_REQUESTS_CLOSED"
    arguments := [handle_, (copy-bounded_ data 31), (copy-bounded_ scan-response 31)]
    completed := false
    try:
      result/bool := false
      error := catch: result = connection_.call_ api.PERIPHERAL-ADVERTISING-UPDATE arguments
      if error:
        completed = error == "INVALID_ARGUMENT" or error == "BLE_ADVERTISING_UPDATE_BUSY" or error == "GATT_NOT_STARTED"
        throw error
      completed = true
      return result
    finally:
      if not completed:
        critical-do --no-respect-deadline: catch: close

  /** Waits for peer identity as an owned address and address-type pair. */
  peer -> List: return connection_.call_ api.PEER [handle_]

  /** Returns achieved security; throws GATT_NOT_CONNECTED before a peer connects. */
  security -> SecuritySnapshot: return SecuritySnapshot (connection_.call_ api.SECURITY [handle_])

  /** Returns the current negotiated ATT MTU, initially 23 after connection. */
  mtu -> int: return connection_.call_ api.MTU [handle_]

  /** Reads an owned snapshot of a retained application value. */
  value handle/int -> ByteArray: return connection_.call_ api.VALUE [handle_, handle]

  /** Replaces a retained application value without sending a notification. */
  set-value handle/int value/ByteArray -> none:
    connection_.call_ api.SET-VALUE [handle_, handle, (copy-bounded_ value 512)]

  /**
  Publishes the complete retained value if the current peer subscribed.

  Throws GATT_VALUE_EXCEEDS_MTU if the value exceeds $mtu minus three bytes.
    Does not transmit a truncated prefix. Returns false when not subscribed.
  */
  notify handle/int -> bool: return connection_.call_ api.NOTIFY [handle_, handle]

  /**
  Retains and publishes each of $values in order in one round trip.

  One RPC costs milliseconds on a small board, so a burst of notifications
    goes through this call. Each value replaces the retained value before its
    notification, as $set-value followed by $notify would. At most 32 values
    of at most 512 bytes each; a value larger than $mtu minus three bytes
    throws GATT_VALUE_EXCEEDS_MTU before anything after it is sent. Returns
    the number sent, which is smaller than $values when the peer is not
    subscribed at the time.
  */
  notify-values handle/int values/List -> int:
    if not 1 <= values.size <= 32: throw "INVALID_ARGUMENT"
    // One length-prefixed buffer: the RPC layer carries a single large byte
    // array better than a list of them.
    total := 0
    values.do: | value/ByteArray |
      if value.size > 512: throw "INVALID_ARGUMENT"
      total += 2 + value.size
    packed := ByteArray total
    offset := 0
    values.do: | value/ByteArray |
      io.LITTLE-ENDIAN.put-uint16 packed offset value.size
      packed.replace (offset + 2) value
      offset += 2 + value.size
    return connection_.call_ api.NOTIFY-VALUES [handle_, handle, packed]

  /**
  Submits a complete value snapshot, or returns null when not subscribed.

  Only one receipt may be outstanding until its wait completes. The value must
    fit the negotiated MTU minus three bytes. The provider owns the confirmation
    deadline, at most thirty seconds, even if the caller cancels its wait.
  */
  indicate handle/int --timeout/Duration=(Duration --s=30) -> Indication?:
    token := connection_.call_ api.INDICATE [handle_, handle, timeout.in-us]
    if token == null: return null
    return Indication this token

  wait-indication_ token/int -> none:
    if Task.current == serving-task_: throw "GATT_INDICATION_WAIT_IN_SERVE"
    connection_.call_ api.WAIT-INDICATION [handle_, token]

  /** Serves scoped read, validation, and accepted-write blocks until closure. */
  serve [read] [validate] [written] -> none:
    if serving_: throw "GATT_ALREADY_SERVING"
    if is-closed: throw "GATT_REQUESTS_CLOSED"
    serving_ = true
    serving-task_ = Task.current
    owner := Task.current
    handling := false
    watcher := task --background::
      reason/string? := null
      error := catch: reason = connection_.wait-closed_ handle_
      critical-do --no-respect-deadline:
        if not termination-reason_: termination-reason_ = error ? error.stringify : reason
        if handling: owner.cancel
    try:
      while true:
        request/Request? := null
        error := catch: request = next
        if error:
          if not termination-reason_: termination-reason_ = error.stringify
          if error == "GATT_PEER_DISCONNECTED": return
          throw error
        handling = true
        try:
          if request.kind == api.READ: read.call request
          else if request.kind == api.VALIDATE-WRITE: validate.call request
          else:
            written.call request.handle request.value
            request.accept
        finally: | is-exception _ |
          critical-do --no-respect-deadline:
            if request.active_ and not request.replied_:
              if request.kind == api.WRITTEN and not is-exception:
                catch: request.accept
              else:
                catch: request.reject 0x0e
            request.active_ = false
            handling = false
    finally:
      critical-do --no-respect-deadline:
        close
        watcher.cancel
        serving-task_ = null

  /**
  Pulls one request; low-level callers must reply or close the session.

  If this call fails, delivery may already have happened at the provider. Close
    the session instead of retrying the pull. The scoped $serve loop does this
    automatically when a pull fails.
  */
  next -> Request:
    if is-closed: throw "GATT_REQUESTS_CLOSED"
    return Request this (connection_.next_ handle_)

  reply_ token/int error/int value/ByteArray -> none:
    if is-closed: throw "GATT_REQUESTS_CLOSED"
    connection_.reply_ handle_ token error value

/** A client-owned request snapshot whose reply token expires at the provider. */
class Request:
  session_/Session
  token_/int
  kind/int
  handle/int
  opcode/int
  deadline/int
  value/ByteArray
  active_/bool := true
  replied_/bool := false

  constructor .session_ record/List:
    token_ = record[0]
    kind = record[1]
    handle = record[2]
    opcode = record[3]
    deadline = record[4]
    value = record[5]

  /** Returns an owned value to a read request. */
  reply value/ByteArray -> none:
    if kind != api.READ: throw "INVALID_ARGUMENT"
    respond_ 0 value

  /** Accepts a proposed write or finishes an accepted-write hook. */
  accept -> none:
    if kind == api.READ: throw "INVALID_ARGUMENT"
    respond_ 0 #[]

  /** Rejects a request with an ATT error, or fails an accepted-write hook. */
  reject error/int -> none:
    if not 1 <= error <= 255: throw "INVALID_ARGUMENT"
    respond_ error #[]

  respond_ error/int value/ByteArray -> none:
    if not active_: throw "GATT_REQUEST_EXPIRED"
    if replied_: throw "GATT_ALREADY_REPLIED"
    session_.reply_ token_ error value
    replied_ = true

/** A bounded service indication receipt; confirmation is not durable peer storage. */
class Indication:
  session_/Session
  token_/int

  constructor .session_ .token_:

  /**
  Waits for protocol confirmation or a terminal error.

  Call outside the session's serving task so its application handler can return.
    A canceled wait can be retried while pending; completion consumes the receipt.
  */
  wait -> none: session_.wait-indication_ token_

/**
An immutable observation of connection security, captured by the provider.

$paired means a verified association on this connection, including successful
  bond resumption. It does not assert durable bond storage or a new pairing.
  $encrypted reports controller encryption; $authenticated additionally requires
  authenticated pairing evidence. Just Works is not authenticated.

This is a snapshot, not a live authorization guard. Later disconnect or security
  failure does not mutate an earlier snapshot. Protected attribute operations
  enforce their security requirements in the protocol owner at access time.
*/
class SecuritySnapshot:
  paired/bool
  encrypted/bool
  authenticated/bool

  constructor values/List:
    if values.size != 3: throw "BLE_INVALID_SECURITY_STATE"
    paired = values[0]
    encrypted = values[1]
    authenticated = values[2]
    if authenticated and (not paired or not encrypted): throw "BLE_INVALID_SECURITY_STATE"

// Check fixed protocol bounds before allocating the RPC ownership snapshot.
// The provider still validates UUID forms, MTU and configured smaller limits.
copy-bounded_ bytes/ByteArray limit/int -> ByteArray:
  if bytes.size > limit: throw "INVALID_ARGUMENT"
  return bytes.copy
