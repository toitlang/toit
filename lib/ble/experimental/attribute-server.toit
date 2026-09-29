// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import crypto.cmac show cmac
import io
import .cccd-store as cccd
import .security-state show SecurityState
import .timeouts as timeouts

/** A bounded GATT database with a static layout. UUIDs use Bluetooth wire byte order. */
class Database:
  attributes_/List := []
  sealed_/bool := false
  service_/int := 0
  characteristic_/int := 0
  value-limit_/int
  mtu-limit_/int
  attribute-limit_/int
  subscribable_/int := 0
  service-changed-cccd_/int := 0
  client-features_/int := 0
  database-hash_/int := 0

  /** The most attributes a database may hold. */
  static MAX-ATTRIBUTES ::= 512
  /**
  The most notifying or indicating characteristics (one CCCD each): saved
    subscriptions count them in one byte. Unreachable below 766 attributes.
  */
  static MAX-SUBSCRIBABLE ::= 255

  /** Client Supported Features bit for Robust Caching (Core 6.3 Vol 3 Part G 7.2). */
  static ROBUST-CACHING ::= 1

  /**
  Creates an empty database of at most $attribute-limit attributes (64 by
    default, at most $MAX-ATTRIBUTES).
  */
  constructor --value-limit/int=20 --mtu-limit/int=23 --attribute-limit/int=64:
    if not 1 <= value-limit <= 512: throw "INVALID_ARGUMENT"
    if not 23 <= mtu-limit <= 517: throw "INVALID_ARGUMENT"
    if not 1 <= attribute-limit <= MAX-ATTRIBUTES: throw "INVALID_ARGUMENT"
    value-limit_ = value-limit
    mtu-limit_ = mtu-limit
    attribute-limit_ = attribute-limit

  /**
  Creates baseline GAP and GATT services for an unbonded server.

  Layouts are sealed during connections, but firmware upgrades may change them.
    Service Changed therefore exists by default. Set $immutable-layout only if
    the layout cannot change for the usable lifetime of the device (Core 6.3
    Vol 3 Part G 2.5 and 7.1). Bonded CCCDs require a trusted session store;
    explicit layout migration uses ConfigurationMigration.

  With $caching the GATT service also has Client Supported Features and
    Database Hash, the Robust Caching pair (Core 6.3 Vol 3 Part G 2.5.2.1,
    7.2 and 7.3): clients that cache the layout check the hash, and a bonded
    client that enabled Robust Caching is told with Database Out Of Sync
    (0x12) when the layout changed since its last connection. Their four
    attributes come on top of $attribute-limit, up to $MAX-ATTRIBUTES.
  */
  constructor.with-defaults --name/string="Toit" --value-limit/int=20 --mtu-limit/int=23
      --attribute-limit/int=64 --immutable-layout/bool=false --caching/bool=false:
    if not 1 <= value-limit <= 512: throw "INVALID_ARGUMENT"
    if not 23 <= mtu-limit <= 517: throw "INVALID_ARGUMENT"
    if not 1 <= attribute-limit <= MAX-ATTRIBUTES: throw "INVALID_ARGUMENT"
    value-limit_ = value-limit
    mtu-limit_ = mtu-limit
    attribute-limit_ = caching ? (min MAX-ATTRIBUTES (attribute-limit + 4)) : attribute-limit
    bytes := name.to-byte-array
    if bytes.size > value-limit: throw "INVALID_ARGUMENT"
    add-service #[0, 0x18]
    add-characteristic #[0, 0x2a] --read --value=bytes
    add-characteristic #[1, 0x2a] --read --value=#[0, 0]
    add-service #[1, 0x18]
    if not immutable-layout:
      handle := add-characteristic #[5, 0x2a] --indicate --value=#[1, 0, 0xff, 0xff]
      service-changed-cccd_ = handle + 1
      (attribute_ handle).application-value = false
    if caching:
      client-features_ = add-characteristic #[0x29, 0x2b] --read --write --value=#[0]
      (attribute_ client-features_).application-value = false
      database-hash_ = add-characteristic #[0x2a, 0x2b] --read --value=(ByteArray 16)
      (attribute_ database-hash_).application-value = false

  /** Returns the configured maximum application value size (at most 512 bytes). */
  value-limit -> int: return value-limit_

  /** Returns the configured receive MTU advertised by server sessions. */
  mtu-limit -> int: return mtu-limit_

  /** Returns the built-in Service Changed value handle, or null when absent. */
  service-changed-handle -> int?:
    return service-changed-cccd_ == 0 ? null : service-changed-cccd_ - 1

  /** Returns the Client Supported Features value handle, or null without caching. */
  client-features-handle -> int?: return client-features_ == 0 ? null : client-features_

  /** Returns the Database Hash value handle, or null without caching. */
  database-hash-handle -> int?: return database-hash_ == 0 ? null : database-hash_

  /**
  Returns the Database Hash of the layout (Core 6.3 Vol 3 Part G 7.3.1):
    AES-CMAC with a zero key over the handle, type and value of every
    service, include, characteristic declaration and extended properties
    descriptor, and the handle and type of every other GATT-defined
    descriptor. Characteristic values do not take part. The result is in
    wire order (least significant byte first).
  */
  database-hash -> ByteArray:
    message := io.Buffer
    attributes_.do: | attribute/Attribute_ |
      uuid := attribute.uuid
      if uuid.size != 2: continue.do
      type := io.LITTLE-ENDIAN.uint16 uuid 0
      with-value := 0x2800 <= type <= 0x2803 or type == 0x2900
      if not with-value and not 0x2901 <= type <= 0x2905: continue.do
      message.little-endian.write-uint16 attribute.handle
      message.write uuid
      if with-value: message.write attribute.value
    return (cmac --key=(ByteArray 16) message.bytes).reverse

  /** Freezes the layout; the Database Hash is fixed from here on. */
  seal_ -> none:
    if sealed_: return
    sealed_ = true
    if database-hash_ != 0: (attribute_ database-hash_).value = database-hash

  /**
  Adds a primary service, or a $secondary one (reachable only through
    another service's include), and returns its declaration handle.
  */
  add-service uuid/ByteArray --secondary/bool=false -> int:
    check-building_ 1
    uuid = normalize_ uuid
    service_ = add_ #[secondary ? 1 : 0, 0x28] uuid true false
    characteristic_ = 0
    return service_

  /**
  Includes the service declared at $service in the latest service and
    returns the include declaration's handle (Core 6.3 Vol 3 Part G 3.2).

  Includes come directly after their service's declaration, before its
    characteristics. The included service must be an earlier one, so its
    handle range is final.
  */
  include-service service/int -> int:
    check-building_ 1
    if service_ == 0 or characteristic_ != 0: throw "INVALID_ARGUMENT"
    included := attribute_ service
    if not included or service >= service_ or
        (included.uuid != #[0, 0x28] and included.uuid != #[1, 0x28]):
      throw "INVALID_ARGUMENT"
    // The included service's range ends before the latest service.
    end := service_ - 1
    attributes_.do: | next/Attribute_ |
      if service < next.handle < service_ and (next.uuid == #[0, 0x28] or next.uuid == #[1, 0x28]):
        end = min end (next.handle - 1)
    value := ByteArray (included.value.size == 2 ? 6 : 4)
    io.LITTLE-ENDIAN.put-uint16 value 0 service
    io.LITTLE-ENDIAN.put-uint16 value 2 end
    if included.value.size == 2: value.replace 4 included.value
    return add_ #[2, 0x28] value true false

  /**
  Adds a bounded value, its declaration, and an optional notification/indication CCCD.

  $write enables acknowledged and prepared writes; $write-command independently
    enables unacknowledged commands. Validation can reject either, but a command
    rejection has no ATT response. Accepted commands retain message boundaries.

  $encrypted requires an encrypted paired connection for access to the value and
    its CCCD. $authenticated additionally requires MITM-protected pairing.
    Declarations remain discoverable. Requirements apply to reads, writes,
    prepared writes and outgoing updates, and default to unrestricted access.
  */
  add-characteristic uuid/ByteArray --read/bool=false --write/bool=false
      --write-command/bool=false
      --notify/bool=false --indicate/bool=false --dynamic-read/bool=false --validate-write/bool=false --value/ByteArray=#[]
      --encrypted/bool=false --authenticated/bool=false -> int:
    if service_ == 0 or value.size > value-limit: throw "INVALID_ARGUMENT"
    if (dynamic-read and not read) or (validate-write and not (write or write-command)): throw "INVALID_ARGUMENT"
    check-building_ ((notify or indicate) ? 3 : 2)
    if (notify or indicate) and subscribable_ >= MAX-SUBSCRIBABLE: throw "GATT_DATABASE_FULL"
    uuid = normalize_ uuid
    properties := (read ? 2 : 0) | (write ? 8 : 0) | (notify ? 0x10 : 0) | (indicate ? 0x20 : 0)
    if write-command: properties |= 4
    if properties == 0: throw "INVALID_ARGUMENT"
    handle := attributes_.size + 2
    declaration := ByteArray (3 + uuid.size)
    declaration[0] = properties
    io.LITTLE-ENDIAN.put-uint16 declaration 1 handle
    declaration.replace 3 uuid
    add_ #[3, 0x28] declaration true false
    add_ uuid value read write
    attribute := attribute_ handle
    attribute.encrypted = encrypted or authenticated
    attribute.authenticated = authenticated
    attribute.application-value = true
    attribute.notifiable = notify
    attribute.indicatable = indicate
    attribute.dynamic-read = dynamic-read
    attribute.validate-write = validate-write
    attribute.command-writable = write-command
    if notify or indicate:
      subscribable_++
      cccd := add_ #[2, 0x29] #[0, 0] true true
      descriptor := attributes_[cccd - 1] as Attribute_
      descriptor.notifies = handle
      descriptor.encrypted = attribute.encrypted
      descriptor.authenticated = attribute.authenticated
    characteristic_ = handle
    return handle

  /**
  Adds a descriptor to the most recently added characteristic.

  Explicit $characteristic rejects accidental attachment to an older value.
    Declaration UUIDs and stack-managed configuration descriptors are reserved.
    Only one User Description descriptor is allowed per characteristic.
    A writable User Description adds a read-only Extended Properties descriptor
    and sets Writable Auxiliaries automatically. Use the returned handle; this
    consumes two attributes. User Descriptions must contain valid UTF-8, including
    after peer writes. Other descriptor formats are the application's responsibility.
  */
  add-descriptor characteristic/int uuid/ByteArray --read/bool=true --write/bool=false
      --value/ByteArray=#[] --encrypted/bool=false --authenticated/bool=false -> int:
    check-building_ 1
    if characteristic == 0 or characteristic != characteristic_ or not (read or write):
      throw "INVALID_ARGUMENT"
    if not (attribute_ characteristic).application-value: throw "INVALID_ARGUMENT"
    if value.size > value-limit: throw "INVALID_ARGUMENT"
    uuid = normalize_ uuid
    description := uuid == #[1, 0x29]
    if uuid.size == 2:
      number := io.LITTLE-ENDIAN.uint16 uuid 0
      if 0x2800 <= number <= 0x2803 or [0x2900, 0x2902, 0x2903].contains number:
        throw "GATT_RESERVED_DESCRIPTOR"
      if number == 0x2901:
        attributes_.do: | attribute/Attribute_ |
          if attribute.handle > characteristic and attribute.uuid == uuid:
            throw "GATT_DUPLICATE_DESCRIPTOR"
    if description and not value.is-valid-string-content: throw "INVALID_ARGUMENT"
    if description and write:
      check-building_ 2
      // Core Vol 3 Part G 3.3.3.1: public read-only metadata, bit 1 only.
      // Prepared descriptor writes do not advertise Reliable Write on the value.
      add_ #[0, 0x29] #[2, 0] true false
    handle := add_ uuid value read write
    attribute := attribute_ handle
    attribute.application-value = true
    attribute.encrypted = encrypted or authenticated
    attribute.authenticated = authenticated
    attribute.user-description = description
    if description and write: (attribute_ (characteristic - 1)).value[0] |= 0x80
    return handle

  /** Replaces an application value without changing the database layout. */
  set-value handle/int value/ByteArray -> none:
    attribute := require-value_ handle
    if value.size > value-limit: throw "INVALID_ARGUMENT"
    if attribute.user-description and not value.is-valid-string-content: throw "INVALID_ARGUMENT"
    attribute.value = copy_ value

  /** Returns an owned snapshot of an application value. */
  value handle/int -> ByteArray:
    return copy_ (require-value_ handle).value

  require-value_ handle/int -> Attribute_:
    attribute := attribute_ handle
    if not attribute or not attribute.application-value: throw "GATT_INVALID_VALUE_HANDLE"
    return attribute

  /**
  Freezes the layout and creates per-connection state.

  A trusted $cccd-store restores one bond's configuration for this exact layout.
    It requires live security evidence; restored subscriptions remain inactive
    until paired encryption is established. Without a store, CCCDs start disabled.
  */
  session --security/SecurityState?=null --handler-timeout/Duration=(Duration --s=1)
      --cccd-store/cccd.Store?=null -> Session:
    return Session this --security=security --handler-timeout=handler-timeout --cccd-store=cccd-store

  /**
  Decodes a stored configuration: format 1 (subscriptions) or 2
    (subscriptions and one octet of client features). The high bit of the
    format octet marks a layout change the client has not seen yet.
  */
  decode-cccd_ state/ByteArray -> Map:
    if state.size < 2 or state.size > 3 + 4 * MAX-SUBSCRIBABLE: throw "GATT_INVALID_CCCD_STATE"
    count := state[1]
    format := state[0] & 0x7f
    if (format != 1 and format != 2) or state.size != (format == 1 ? 2 : 3) + count * 4:
      throw "GATT_INVALID_CCCD_STATE"
    features := decode-features_ state
    if features & ~ROBUST-CACHING != 0 or (format == 2 and (features == 0 or client-features_ == 0)):
      throw "GATT_INVALID_CCCD_STATE"
    subscriptions := {:}
    previous := 0
    count.repeat: | index/int |
      offset := 2 + index * 4
      handle := io.LITTLE-ENDIAN.uint16 state offset
      attribute := attribute_ handle
      value := state[offset + 2..offset + 4]
      if handle <= previous or not attribute or attribute.notifies == 0 or
          value[0] == 0 or not (valid-cccd_ attribute value):
        throw "GATT_INVALID_CCCD_STATE"
      subscriptions[attribute.notifies] = value[0]
      previous = handle
    if state[0] & 0x80 != 0 and not (tracks-change_ subscriptions features):
      throw "GATT_INVALID_CCCD_STATE"
    return subscriptions

  /** The client features in a stored configuration. */
  decode-features_ state/ByteArray -> int:
    return state[0] & 0x7f == 2 ? state.last : 0

  /**
  Whether a pending layout change can reach the client: by a Service Changed
    indication, or by Database Out Of Sync with Robust Caching.
  */
  tracks-change_ subscriptions/Map features/int -> bool:
    return (subscriptions.get (service-changed-cccd_ - 1) --if-absent=: 0) == 2 or
        features & ROBUST-CACHING != 0

  encode-cccd_ subscriptions/Map --changed/bool=false --features/int=0 -> ByteArray:
    count := 0
    attributes_.do: | attribute/Attribute_ |
      if attribute.notifies != 0 and (subscriptions.get attribute.notifies --if-absent=: 0) != 0:
        count++
    state := ByteArray ((features == 0 ? 2 : 3) + count * 4)
    state[0] = (changed ? 0x80 : 0) | (features == 0 ? 1 : 2)
    state[1] = count
    if features != 0: state[state.size - 1] = features
    offset := 2
    attributes_.do: | attribute/Attribute_ |
      if attribute.notifies == 0: continue.do
      bits/int := subscriptions.get attribute.notifies --if-absent=: 0
      if bits == 0: continue.do
      io.LITTLE-ENDIAN.put-uint16 state offset attribute.handle
      io.LITTLE-ENDIAN.put-uint16 state (offset + 2) bits
      offset += 4
    return state

  valid-cccd_ descriptor/Attribute_ value/ByteArray -> bool:
    target := attribute_ descriptor.notifies
    allowed := (target.notifiable ? 1 : 0) | (target.indicatable ? 2 : 0)
    return value.size == 2 and value[1] == 0 and (value[0] & ~allowed) == 0

  check-building_ count/int -> none:
    if sealed_: throw "GATT_DATABASE_SEALED"
    if attributes_.size + count > attribute-limit_: throw "GATT_DATABASE_FULL"

  add_ uuid/ByteArray value/ByteArray read/bool write/bool -> int:
    handle := attributes_.size + 1
    attributes_.add (Attribute_ handle (copy_ uuid) (copy_ value) read write)
    return handle

  attribute_ handle/int -> Attribute_?:
    if not 1 <= handle <= attributes_.size: return null
    return attributes_[handle - 1]

  end_ attribute/Attribute_ -> int:
    characteristic := attribute.uuid == #[3, 0x28]
    if not characteristic and attribute.uuid != #[0, 0x28] and attribute.uuid != #[1, 0x28]:
      return attribute.handle
    end := attributes_.size
    attributes_.do: | next/Attribute_ |
      if next.handle > attribute.handle and
          (next.uuid == #[0, 0x28] or next.uuid == #[1, 0x28] or
            (characteristic and next.uuid == #[3, 0x28])):
        return next.handle - 1
    return end

/**
Maps subscriptions between two provider-owned layouts before accepting peers.

The explicit mapping uses old CCCD handles as keys and new CCCD handles as
  values. Zero means the characteristic was removed. Every old application CCCD
  must occur exactly once, including disabled ones. Surviving characteristics
  must retain their UUID and notification/indication properties; the provider
  asserts their semantic identity, including when duplicate UUIDs exist.
  New characteristics start disabled. Service Changed is mapped automatically
  and must retain its handle while bonds exist (Core 6.3 Vol 3 Part G 7.1).
  Successful construction seals both layouts. No live database mutation occurs.
*/
class ConfigurationMigration:
  before_/Database
  after_/Database
  mapping_/Map

  constructor .before_ .after_ mapping/Map:
    if not before_.service-changed-handle or before_.service-changed-handle != after_.service-changed-handle:
      throw "GATT_SERVICE_CHANGED_HANDLE_CHANGED"
    mapping_ = {:}
    targets := {}
    before_.attributes_.do: | descriptor/Attribute_ |
      if descriptor.notifies == 0 or descriptor.handle == before_.service-changed-cccd_:
        continue.do
      target/int? := mapping.get descriptor.handle
      if target == null: throw "GATT_INCOMPLETE_CCCD_MIGRATION"
      mapping_[descriptor.handle] = target
      if target == 0: continue.do
      next := after_.attribute_ target
      if not next or next.notifies == 0 or target == after_.service-changed-cccd_ or targets.contains target:
        throw "GATT_INVALID_CCCD_MIGRATION"
      old-value := before_.attribute_ descriptor.notifies
      new-value := after_.attribute_ next.notifies
      if old-value.uuid != new-value.uuid or old-value.notifiable != new-value.notifiable or
          old-value.indicatable != new-value.indicatable:
        throw "GATT_INVALID_CCCD_MIGRATION"
      targets.add target
    if mapping_.size != mapping.size: throw "GATT_INVALID_CCCD_MIGRATION"
    mapping_[before_.service-changed-cccd_] = after_.service-changed-cccd_
    before_.seal_
    after_.seal_

  /** Returns a complete new snapshot, retaining a pending full-range change notice. */
  apply state/ByteArray? -> ByteArray:
    previous := state ? before_.decode-cccd_ state.copy : {:}
    subscriptions := {:}
    mapping_.do: | source/int target/int |
      if target == 0: continue.do
      bits := previous.get (before_.attribute_ source).notifies --if-absent=: 0
      if bits != 0: subscriptions[(after_.attribute_ target).notifies] = bits
    features := state and after_.client-features_ != 0 ? before_.decode-features_ state : 0
    changed := after_.tracks-change_ subscriptions features
    return after_.encode-cccd_ subscriptions --changed=changed --features=features

class Attribute_:
  handle/int
  uuid/ByteArray
  value/ByteArray := ?
  readable/bool
  writable/bool
  command-writable/bool := false
  encrypted/bool := false
  authenticated/bool := false
  notifies/int := 0
  application-value/bool := false
  notifiable/bool := false
  indicatable/bool := false
  dynamic-read/bool := false
  validate-write/bool := false
  user-description/bool := false

  constructor .handle .uuid .value .readable .writable:

/** A reply valid only during its handler block and before its deadline. */
class Request:
  handle/int
  opcode/int
  deadline_/int
  active_/bool := true
  replied_/bool := false
  error_/int := 0

  constructor .handle .opcode .deadline_:

  /** Returns the monotonic microsecond deadline for this scoped request. */
  deadline -> int: return deadline_

  /** Rejects this request with an ATT error code. */
  reject code/int -> none:
    check-reply_
    if not 1 <= code <= 255: throw "INVALID_ARGUMENT"
    error_ = code
    replied_ = true

  check-reply_ -> none:
    if not active_ or Time.monotonic-us >= deadline_: throw "GATT_REQUEST_EXPIRED"
    if replied_: throw "GATT_ALREADY_REPLIED"

/** A scoped application reply to a dynamic read. */
class ReadRequest extends Request:
  value_/ByteArray? := null
  value-limit_/int

  constructor handle/int opcode/int deadline/int --value-limit/int=20:
    if not 1 <= value-limit <= 512: throw "INVALID_ARGUMENT"
    value-limit_ = value-limit
    super handle opcode deadline

  /** Supplies an owned value, bounded by the database's configured value limit. */
  reply value/ByteArray -> none:
    check-reply_
    if value.size > value-limit_: throw "INVALID_ARGUMENT"
    value_ = value.copy
    replied_ = true

/** A proposed value to validate before commit; changing it does not rewrite it. */
class WriteRequest extends Request:
  value/ByteArray

  constructor handle/int opcode/int deadline/int value/ByteArray:
    this.value = value.copy
    super handle opcode deadline

  /** Accepts the proposed write without committing it yet. */
  accept -> none:
    check-reply_
    replied_ = true

/**
An ATT server session with independent MTU and notification configuration.

Processes complete ATT PDUs, returning a response or null for commands. This
  initial engine has retained values, scoped read/write validation, explicit security requirements, and
  no transport dependency.
  Core 6.3 Vol 3 Part F sections 3.4.2 through 3.4.5 define the wire procedures.
*/
class Session:
  database_/Database
  security_/SecurityState?
  cccd-store_/cccd.Store?
  saving-cccd_/bool := false
  service-changed-pending_/bool := false
  client-features_/int := 0
  out-of-sync-sent_/bool := false
  hash-read_/bool := false
  subscriptions_/Map := {:}
  closed_/bool := false
  prepared_/List := []
  accepted_/List := []
  handler-timeout_/Duration
  active-request_/Request? := null
  prepare-limit_/int
  prepare-budget_/int
  prepared-bytes_/int := 0
  mtu_/int := 23
  pending-mtu_/int? := null

  constructor .database_ --handler-timeout/Duration=(Duration --s=1) --security/SecurityState?=null
      --cccd-store/cccd.Store?=null:
    security_ = security
    cccd-store_ = cccd-store
    if handler-timeout.in-us <= 0: throw "INVALID_ARGUMENT"
    if cccd-store and not security: throw "GATT_CCCD_SECURITY_REQUIRED"
    handler-timeout_ = handler-timeout
    // Enough MTU-23 fragments for one maximum-sized value, with the existing
    // eight-entry minimum for small multi-attribute transactions.
    prepare-limit_ = max 8 ((database_.value-limit + 17) / 18)
    prepare-budget_ = prepare-limit_ * 18
    if cccd-store:
      saved/ByteArray? := null
      with-timeout timeouts.STORE: saved = cccd-store.load
      if saved: restore-cccd_ saved
    database_.seal_

  /** Returns the effective MTU, initially 23. */
  mtu -> int: return mtu_

  /**
  Applies a pending MTU after its exchange response has been submitted.

  A transport adapter must call this after successfully sending the response
    returned by request, before sending any subsequent ATT PDU.
  */
  response-sent -> none:
    if pending-mtu_:
      mtu_ = pending-mtu_
      pending-mtu_ = null

  /** Returns whether notifications are enabled for the given value handle. */
  subscribed handle/int --indications/bool=false -> bool:
    if cccd-store_ and not (security_.paired and security_.encrypted): return false
    if service-changed-pending_ and handle != database_.service-changed-handle: return false
    return ((subscriptions_.get handle --if-absent=: 0) & (indications ? 2 : 1)) != 0

  /** Reports a pending change that can be sent over this secured connection. */
  service-changed-pending -> bool:
    return service-changed-pending_ and (subscribed database_.service-changed-handle --indications)

  /** Returns the fixed Service Changed handle, or null when absent. */
  service-changed-handle -> int?: return database_.service-changed-handle

  /** The client's supported features (Core 6.3 Vol 3 Part G 7.2), restored for a bond. */
  client-features -> int: return client-features_

  /**
  Whether the client is change-unaware (Core 6.3 Vol 3 Part G 2.5.2.1): it
    enabled Robust Caching and has not seen a layout change yet. Its
    commands are ignored, and its first request gets Database Out Of Sync.
    It becomes change-aware when it confirms the Service Changed
    indication, or with its next request after that error or after reading
    the Database Hash.
  */
  change-unaware -> bool:
    return service-changed-pending_ and client-features_ & Database.ROBUST-CACHING != 0 and
        security_ != null and security_.paired and security_.encrypted

  /**
  Durably clears a pending change after its indication was confirmed.

  Only the ATT transport may call this for the sole outstanding Service Changed
    indication. A failure closes the session; an uncommitted clear causes a
    repeated indication after reconnect. Application updates remain suppressed
    until the clear succeeds.
  */
  confirm-service-changed -> none:
    check-open_
    if not service-changed-pending_: return
    if active-request_ or saving-cccd_: throw "GATT_REQUEST_BUSY"
    if not service-changed-pending: throw "GATT_INSUFFICIENT_SECURITY"
    save-cccd_ subscriptions_ false

  /**
  Builds a notification snapshot, or returns null when not subscribed.

  When $truncate is false, an oversized subscribed value throws
    GATT_VALUE_EXCEEDS_MTU instead of producing an MTU-sized prefix.
  */
  notification handle/int --truncate/bool=true -> ByteArray?:
    check-open_
    attribute := database_.require-value_ handle
    if not attribute.notifiable: throw "GATT_NOT_NOTIFIABLE"
    if not (subscribed handle): return null
    return value-packet_ attribute 0x1b --truncate=truncate

  /** Builds an indication snapshot, or returns null when not subscribed. */
  indication handle/int --truncate/bool=true -> ByteArray?:
    check-open_
    attribute := database_.attribute_ handle
    if not attribute or not (attribute.application-value or handle == database_.service-changed-cccd_ - 1):
      throw "GATT_INVALID_VALUE_HANDLE"
    if not attribute.indicatable: throw "GATT_NOT_INDICATABLE"
    if not (subscribed handle --indications): return null
    return value-packet_ attribute 0x1d --truncate=truncate

  value-packet_ attribute/Attribute_ opcode/int --truncate/bool=true -> ByteArray:
    if (security-error_ attribute) != 0: throw "GATT_INSUFFICIENT_SECURITY"
    if not truncate and attribute.value.size > mtu_ - 3: throw "GATT_VALUE_EXCEEDS_MTU"
    length := min attribute.value.size (mtu_ - 3)
    result := ByteArray (3 + length)
    result[0] = opcode
    io.LITTLE-ENDIAN.put-uint16 result 1 attribute.handle
    result.replace 3 attribute.value[0..length]
    return result

  /** Invalidates this connection's state and rejects subsequent requests. */
  close -> none:
    closed_ = true
    subscriptions_.clear
    prepared_.clear
    prepared-bytes_ = 0
    pending-mtu_ = null
    accepted_.clear
    if active-request_: active-request_.active_ = false

  /** Delivers application writes once, excluding the internal Service Changed CCCD. */
  writes-do [written] -> none:
    entries := accepted_
    accepted_ = []
    entries.do: | entry/List |
      if entry[0] != database_.service-changed-cccd_ and entry[0] != database_.client-features_:
        written.call entry[0] entry[1].copy

  check-open_ -> none:
    if closed_: throw "ATT_SERVER_CLOSED"

  /** Handles discovery, MTU exchange, reads, and small writes. */
  request pdu/ByteArray -> ByteArray?:
    return request pdu (: | read/ReadRequest | read.reject 0x0e)

  /** Handles a PDU with a scoped handler for dynamic readable values. */
  request pdu/ByteArray [read] -> ByteArray?:
    return request pdu read (: | write/WriteRequest | write.reject 0x0e)

  /** Handles dynamic reads and validates proposed writes before committing. */
  request pdu/ByteArray [read] [validate] -> ByteArray?:
    check-open_
    if active-request_ or saving-cccd_: throw "GATT_REQUEST_BUSY"
    accepted_ = []
    if pdu.is-empty: throw "ATT_INVALID_PDU"
    opcode := pdu[0]
    // Commands never receive a response, including malformed or denied writes.
    if opcode & 0x40 != 0:
      if opcode == 0x52 and not change-unaware: write-command_ pdu validate
      return null
    if pdu.size > mtu_: return error_ opcode 0 4
    if opcode != 2 and change-unaware:
      if opcode == 8 and (pdu.size == 7 or pdu.size == 21) and (normalize_ pdu[5..]) == #[0x2a, 0x2b]:
        hash-read_ = true
      else if hash-read_ or out-of-sync-sent_:
        save-cccd_ subscriptions_ false
      else:
        out-of-sync-sent_ = true
        return error_ opcode (opcode == 0x18 or pdu.size < 3 ? 0 : io.LITTLE-ENDIAN.uint16 pdu 1) 0x12
    if opcode == 0x16:
      if pdu.size < 5: return error_ opcode 0 4
      handle := io.LITTLE-ENDIAN.uint16 pdu 1
      attribute := database_.attribute_ handle
      if not attribute: return error_ opcode handle 1
      if not attribute.writable: return error_ opcode handle 3
      security-error := security-error_ attribute
      if security-error != 0: return error_ opcode handle security-error
      if prepared_.size == prepare-limit_ or prepared-bytes_ + pdu.size - 5 > prepare-budget_:
        return error_ opcode handle 9
      // Offset and value validation belongs to Execute Write (3.4.6.1).
      // Allocate the reply before changing the queue: a failed request must
      // not leave an unacknowledged fragment for a later Execute Write.
      response := pdu.copy
      response[0] = 0x17
      prepared_.add pdu.copy
      prepared-bytes_ += pdu.size - 5
      return response
    if opcode == 0x18:
      if pdu.size != 2 or pdu[1] > 1: return error_ opcode 0 4
      queued := prepared_
      prepared_ = []
      prepared-bytes_ = 0
      if pdu[1] == 0: return #[0x19]
      return execute_ queued validate
    if opcode == 2:
      if pdu.size != 3: return error_ opcode 0 4
      peer := io.LITTLE-ENDIAN.uint16 pdu 1
      pending-mtu_ = peer < 23 ? 23 : (min peer database_.mtu-limit)
      response := #[3, 0, 0]
      io.LITTLE-ENDIAN.put-uint16 response 1 database_.mtu-limit
      return response
    if opcode == 4 or opcode == 6 or opcode == 8 or opcode == 0x10:
      valid := pdu.size == 7 or pdu.size == 21
      if opcode == 4: valid = pdu.size == 5
      if opcode == 6: valid = pdu.size >= 7
      if not valid: return error_ opcode 0 4
      start := io.LITTLE-ENDIAN.uint16 pdu 1
      end := io.LITTLE-ENDIAN.uint16 pdu 3
      if not 1 <= start <= end: return error_ opcode start 1
      type/ByteArray? := null
      if opcode != 4: type = normalize_ pdu[5..(opcode == 6 ? 7 : pdu.size)]
      if opcode == 0x10 and type != #[0, 0x28] and type != #[1, 0x28]:
        return error_ opcode start 0x10
      result := ByteArray mtu_
      result[0] = opcode + 1
      used := opcode == 6 ? 1 : 2
      width := 0
      value-size := -1
      for i := 0; i < database_.attributes_.size; i++:
        attribute/Attribute_ := database_.attributes_[i]
        if not start <= attribute.handle <= end: continue
        if type and attribute.uuid != type: continue
        security-error := opcode == 4 ? 0 : (security-error_ attribute)
        if security-error != 0:
          if opcode == 6: continue
          if width == 0: return error_ opcode attribute.handle security-error
          break
        value := value_ attribute
        if opcode != 4 and attribute.readable and attribute.dynamic-read:
          reply := read_ attribute opcode read
          if reply.error_ != 0:
            if opcode == 6: continue
            if width == 0: return error_ opcode attribute.handle reply.error_
            break
          value = reply.value_
        if opcode == 6 and (not attribute.readable or value != pdu[7..]): continue
        if opcode != 4 and opcode != 6 and not attribute.readable:
          if width == 0: return error_ opcode attribute.handle 2
          break
        entry := opcode == 4 ? attribute.uuid : value
        // Read By Type/Group Type pages require equal original value lengths,
        // even when truncation would give different values the same wire width.
        if opcode == 8 or opcode == 0x10:
          if value-size >= 0 and entry.size != value-size: break
          value-size = entry.size
        prefix := opcode == 6 or opcode == 0x10 ? 4 : 2
        entry-size := opcode == 6 ? 0 : min entry.size (min (mtu_ - 2 - prefix) (255 - prefix))
        next-width := prefix + entry-size
        if width != 0 and width != next-width: break
        if used + next-width > mtu_: break
        width = next-width
        io.LITTLE-ENDIAN.put-uint16 result used attribute.handle
        if prefix == 4:
          io.LITTLE-ENDIAN.put-uint16 result (used + 2) (database_.end_ attribute)
        if entry-size > 0: result.replace (used + prefix) entry[0..entry-size]
        used += width
      if width == 0: return error_ opcode start 0x0a
      // A later dynamic handler can wait after earlier values were copied.
      // Recheck included values before returning the combined response.
      if opcode != 4:
        offset := opcode == 6 ? 1 : 2
        while offset < used:
          handle := io.LITTLE-ENDIAN.uint16 result offset
          security-error := security-error_ (database_.attribute_ handle)
          if security-error != 0:
            if offset == (opcode == 6 ? 1 : 2):
              return error_ opcode (opcode == 6 ? start : handle) (opcode == 6 ? 0x0a : security-error)
            used = offset
            break
          offset += width
      if opcode != 6: result[1] = opcode == 4 ? (width == 4 ? 1 : 2) : width
      return result[0..used]
    if opcode == 0x0e or opcode == 0x20:
      // Read Multiple (Vol 3 Part F 3.4.4.7) concatenates the values; the
      // variable-length form (3.4.4.11) prefixes each with its length. Both
      // stop at the MTU. Any refused handle refuses the whole request.
      if pdu.size < 5 or (pdu.size - 1) % 2 != 0: return error_ opcode 0 4
      response := #[opcode + 1]
      ((pdu.size - 1) / 2).repeat: | index/int |
        handle := io.LITTLE-ENDIAN.uint16 pdu (1 + index * 2)
        attribute := database_.attribute_ handle
        if not attribute: return error_ opcode handle 1
        if not attribute.readable: return error_ opcode handle 2
        security-error := security-error_ attribute
        if security-error != 0: return error_ opcode handle security-error
        value := value_ attribute
        if attribute.dynamic-read:
          reply := read_ attribute opcode read
          if reply.error_ != 0: return error_ opcode handle reply.error_
          value = reply.value_
        if opcode == 0x20: response += #[value.size & 0xff, value.size >> 8]
        response += value
      if response.size > mtu_: response = response[..mtu_]
      return response
    if opcode == 0x0a or opcode == 0x0c or opcode == 0x12:
      if pdu.size < 3 or (opcode == 0x0a and pdu.size != 3) or (opcode == 0x0c and pdu.size != 5):
        return error_ opcode 0 4
      handle := io.LITTLE-ENDIAN.uint16 pdu 1
      attribute := database_.attribute_ handle
      if not attribute: return error_ opcode handle 1
      if opcode == 0x0a or opcode == 0x0c:
        if not attribute.readable: return error_ opcode handle 2
        security-error := security-error_ attribute
        if security-error != 0: return error_ opcode handle security-error
        value := value_ attribute
        if attribute.dynamic-read:
          reply := read_ attribute opcode read
          if reply.error_ != 0: return error_ opcode handle reply.error_
          value = reply.value_
        offset := opcode == 0x0c ? (io.LITTLE-ENDIAN.uint16 pdu 3) : 0
        if offset > value.size: return error_ opcode handle 7
        length := min (value.size - offset) (mtu_ - 1)
        response := ByteArray (1 + length)
        response[0] = opcode + 1
        response.replace 1 value[offset..offset + length]
        return response
      if not attribute.writable: return error_ opcode handle 3
      security-error := security-error_ attribute
      if security-error != 0: return error_ opcode handle security-error
      value := pdu[3..].copy
      if handle == database_.client-features_: return write-client-features_ attribute value
      if attribute.application-value and value.size > database_.value-limit:
        return error_ opcode handle 0x0d
      if attribute.user-description and not value.is-valid-string-content:
        return error_ opcode handle 0x13
      if attribute.validate-write:
        validation := WriteRequest handle opcode (Time.monotonic-us + handler-timeout_.in-us) value
        invoke_ validation validate
        if validation.error_ != 0: return error_ opcode handle validation.error_
      security-error = security-error_ attribute
      if security-error != 0: return error_ opcode handle security-error
      // Build the reply and accepted-write record before publishing state, so
      // a failure cannot change a value without its matching write record.
      accepted := [[handle, value]]
      response := #[0x13]
      if attribute.notifies != 0:
        if value.size != 2: return error_ opcode handle 0x0d
        if not (valid-cccd_ attribute value): return error_ opcode handle 0x13
        if cccd-store_:
          subscriptions := subscriptions_.copy
          subscriptions[attribute.notifies] = value[0]
          save-cccd_ subscriptions service-changed-pending_
          if (security-error_ attribute) != 0:
            close
            throw "GATT_INSUFFICIENT_SECURITY"
          subscriptions_ = subscriptions
        else:
          subscriptions_[attribute.notifies] = value[0]
      else:
        attribute.value = value
      // This snapshot is private: validators and public value/hook accessors
      // receive copies. Replacing the attribute later preserves this record.
      accepted_ = accepted
      return response
    return error_ opcode 0 6

  /**
  Enables client features. Only Robust Caching is supported; other bits are
    ignored, and a client cannot disable a feature it enabled (Value Not
    Allowed).
  */
  write-client-features_ attribute/Attribute_ value/ByteArray -> ByteArray:
    if value.is-empty: return error_ 0x12 attribute.handle 0x0d
    if client-features_ & ~value[0] != 0: return error_ 0x12 attribute.handle 0x13
    features := client-features_ | (value[0] & Database.ROBUST-CACHING)
    if features != client-features_:
      if cccd-store_:
        save-cccd_ subscriptions_ service-changed-pending_ --features=features
        if (security-error_ attribute) != 0:
          close
          throw "GATT_INSUFFICIENT_SECURITY"
      else:
        client-features_ = features
    return #[0x13]

  write-command_ pdu/ByteArray [validate] -> none:
    if pdu.size < 3 or pdu.size > mtu_: return
    handle := io.LITTLE-ENDIAN.uint16 pdu 1
    attribute := database_.attribute_ handle
    if not attribute or not attribute.command-writable: return
    if (security-error_ attribute) != 0: return
    value := pdu[3..].copy
    if value.size > database_.value-limit: return
    if attribute.validate-write:
      validation := WriteRequest handle 0x52 (Time.monotonic-us + handler-timeout_.in-us) value
      invoke_ validation validate
      if validation.error_ != 0: return
    if (security-error_ attribute) != 0: return
    accepted := [[handle, value]]
    attribute.value = value
    accepted_ = accepted

  security-error_ attribute/Attribute_ -> int:
    per-client := attribute.notifies != 0 or attribute.handle == database_.client-features_
    if not attribute.encrypted and not (cccd-store_ and per-client): return 0
    // GAP Vol 3 Part C 10.3.1: no key requires pairing; an existing key
    // without encryption requires encryption, regardless of MITM policy.
    if not security_ or not security_.paired: return 5
    if not security_.encrypted: return 0x0f
    if attribute.authenticated and not security_.authenticated: return 5
    return 0

  valid-cccd_ descriptor/Attribute_ value/ByteArray -> bool:
    return database_.valid-cccd_ descriptor value

  value_ attribute/Attribute_ -> ByteArray:
    if attribute.notifies != 0:
      return #[(subscriptions_.get attribute.notifies --if-absent=: 0), 0]
    if attribute.handle == database_.client-features_: return #[client-features_]
    return attribute.value

  restore-cccd_ state/ByteArray -> none:
    state = state.copy
    subscriptions_ = database_.decode-cccd_ state
    client-features_ = database_.decode-features_ state
    service-changed-pending_ = state[0] & 0x80 != 0

  /**
  Saves the configuration. A save that clears the pending change also makes
    the client change-aware.
  */
  save-cccd_ subscriptions/Map changed/bool --features/int=client-features_ -> none:
    changed = changed and (database_.tracks-change_ subscriptions features)
    state := database_.encode-cccd_ subscriptions --changed=changed --features=features
    succeeded := false
    saving-cccd_ = true
    try:
      with-timeout timeouts.STORE: cccd-store_.save state
      check-open_
      if not (security_.paired and security_.encrypted): throw "GATT_INSUFFICIENT_SECURITY"
      service-changed-pending_ = changed
      client-features_ = features
      if not changed:
        out-of-sync-sent_ = false
        hash-read_ = false
      succeeded = true
    finally:
      saving-cccd_ = false
      if not succeeded: close

  read_ attribute/Attribute_ opcode/int [read] -> ReadRequest:
    if active-request_: throw "GATT_REQUEST_BUSY"
    request := ReadRequest attribute.handle opcode (Time.monotonic-us + handler-timeout_.in-us)
        --value-limit=database_.value-limit
    invoke_ request read
    security-error := security-error_ attribute
    if security-error != 0: request.error_ = security-error
    return request

  invoke_ request/Request [handler] -> none:
    active-request_ = request
    error := null
    try:
      error = catch:
        with-timeout handler-timeout_: handler.call request
    finally:
      critical-do --no-respect-deadline:
        request.active_ = false
        active-request_ = null
    check-open_
    if error or not request.replied_:
      request.error_ = 0x0e

  execute_ queued/List [validate] -> ByteArray:
    staged := {:}
    writes := []
    subscriptions := subscriptions_.copy
    features := client-features_
    queued.do: | pdu/ByteArray |
      handle := io.LITTLE-ENDIAN.uint16 pdu 1
      offset := io.LITTLE-ENDIAN.uint16 pdu 3
      attribute := database_.attribute_ handle
      security-error := security-error_ attribute
      if security-error != 0: return error_ 0x18 handle security-error
      current/ByteArray := staged.get handle --if-absent=: value_ attribute
      if offset > current.size: return error_ 0x18 handle 7
      length := offset + pdu.size - 5
      if length > (attribute.notifies != 0 ? 2 : database_.value-limit): return error_ 0x18 handle 0x0d
      // Characteristic values are variable length; CCCDs have fixed length.
      next := ByteArray (attribute.notifies != 0 ? 2 : length)
      next.replace 0 current[0..(min current.size next.size)]
      next.replace offset pdu[5..]
      if attribute.notifies != 0:
        if not (valid-cccd_ attribute next): return error_ 0x18 handle 0x13
        subscriptions[attribute.notifies] = next[0]
      if handle == database_.client-features_:
        if next.is-empty or client-features_ & ~next[0] != 0: return error_ 0x18 handle 0x13
        features = client-features_ | (next[0] & Database.ROBUST-CACHING)
      staged[handle] = next
      writes.add [handle, next]
    committed := []
    staged.do: | handle/int value/ByteArray | committed.add [handle, value]
    committed.do: | entry/List |
      attribute := database_.attribute_ entry[0]
      security-error := security-error_ attribute
      if security-error != 0: return error_ 0x18 entry[0] security-error
      if attribute.user-description and not (entry[1] as ByteArray).is-valid-string-content:
        return error_ 0x18 entry[0] 0x13
      if attribute.validate-write:
        validation := WriteRequest entry[0] 0x18 (Time.monotonic-us + handler-timeout_.in-us) entry[1]
        invoke_ validation validate
        if validation.error_ != 0: return error_ 0x18 entry[0] validation.error_
    // A scoped validator may wait while the connection's security changes.
    // Recheck every staged attribute after all application code has returned.
    committed.do: | entry/List |
      security-error := security-error_ (database_.attribute_ entry[0])
      if security-error != 0: return error_ 0x18 entry[0] security-error
    // All allocation and validation precedes mutation. No application code is
    // called while committing the transaction, including repeated handles.
    response := #[0x19]
    if cccd-store_ and (features != client-features_ or
        (writes.any: | entry/List | (database_.attribute_ entry[0]).notifies != 0)):
      save-cccd_ subscriptions service-changed-pending_ --features=features
      committed.do: | entry/List |
        if (security-error_ (database_.attribute_ entry[0])) != 0:
          close
          throw "GATT_INSUFFICIENT_SECURITY"
    critical-do --no-respect-deadline:
      writes.do: | entry/List |
        attribute := database_.attribute_ entry[0]
        if attribute.notifies == 0 and entry[0] != database_.client-features_: attribute.value = entry[1]
      subscriptions_ = subscriptions
      client-features_ = features
      accepted_ = committed
    return response

error_ opcode/int handle/int code/int -> ByteArray:
  result := #[1, opcode, 0, 0, code]
  io.LITTLE-ENDIAN.put-uint16 result 2 handle
  return result

normalize_ uuid/ByteArray -> ByteArray:
  if uuid.size == 2: return copy_ uuid
  if uuid.size != 16: throw "INVALID_UUID"
  if uuid[0..12] == #[0xfb, 0x34, 0x9b, 0x5f, 0x80, 0, 0, 0x80, 0, 0x10, 0, 0] and
      uuid[14] == 0 and uuid[15] == 0:
    return copy_ uuid[12..14]
  return copy_ uuid

copy_ bytes/ByteArray -> ByteArray:
  result := ByteArray bytes.size
  result.replace 0 bytes
  return result
