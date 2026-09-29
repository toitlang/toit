// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import monitor

import ..attribute-server as attributes
import ..cccd-store as cccd
import ..bounded-central as bounded
import ..central as central
import ..controller-states as states
import ..gatt-server as gatt
import ..security as security
import ..hci as hci
import ..advertising-updates as advertising-updates
import ..security-owner show Owner
import ..transport as transport
import .api as api
import .gatt-client-operations as operations
import .link-operations as link-operations
import .provider as rpc
import .central-provider as central-provider
import .shared-host as shared
import ..timeouts as timeouts
import io

/** Provides one configured peripheral, with all protocol work in this process. */
abstract class Provider extends central-provider.Provider:
  constructor:
    super

  /** Opens the exclusively owned controller transport in the serving task. */
  abstract open-transport -> transport.Transport

  /**
  Selects a shared lifetime for a peripheral worker, or null for exclusive use.

  An explicit shared provider must use $reserve-shared-host and supply one
    $create-shared-host policy for both roles, including early security hooks.
    This hook alone does not relax RPC admission.
  */
  reserve-peripheral-host -> shared.Host?:
    if mixed-role-sessions or peripheral-session-limit > 1: return reserve-shared-host
    return null

  /**
  Lets central and peripheral sessions share the controller.

  False by default. When true the provider serves both roles at once, up to
    $central-session-limit centrals and $peripheral-session-limit
    peripherals, through the extended command family; controllers that
    cannot advertise connectably while connected as central (and initiate
    while connected as peripheral) fail the first session with
    GATT_MIXED_CONTROLLER_UNSUPPORTED.
  */
  mixed-role-sessions -> bool: return false

  /** One central session by default, two with $mixed-role-sessions; at most eight. */
  central-session-limit -> int: return mixed-role-sessions ? 2 : 1

  /**
  Sizes the shared host for mixed roles or several peripheral links.

  Mixed roles use the extended command family with two links; several
    peripheral sessions advertise again while they already have links.
  */
  create-shared-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    if mixed-role-sessions:
      configure-mixed-roles controller info
      return bounded.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
          --accept-parameter-requests=accept-parameter-requests
          --receive-limit=receive-limit
          --link-limit=(central-session-limit + peripheral-session-limit)
          --early-acl-timeout=early-acl-timeout
    return central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count --phy-2m=info.phy-2m
        --accept-parameter-requests=accept-parameter-requests
        --receive-limit=receive-limit
        --link-limit=(max central-session-limit peripheral-session-limit)

  capabilities -> List:
    flags := api.CAP-ADVERTISING | api.CAP-SCAN | api.CAP-CONTINUOUS-SCAN | api.CAP-GATT-PERIPHERAL | api.CAP-GATT-CENTRAL
    if mixed-role-sessions: flags |= api.CAP-MIXED-ROLES
    // Sessions that can hold the controller at once.
    sessions := mixed-role-sessions
        ? central-session-limit + peripheral-session-limit
        : (max central-session-limit peripheral-session-limit)
    return [flags, 60_000_000, 512, 517, sessions]

  /** Creates a fresh, bounded database for an application session. */
  create-database -> attributes.Database: return attributes.Database.with-defaults --caching

  /**
  Selects trusted CCCD storage for one bond and this exact database revision.

  Called after the security owner is created, before ATT serving and pairing
    start. The default keeps configuration connection-local. An override must
    bind the store to the resolved bond lifetime and stable database context;
    store access is never supplied through application RPC. Loaded subscriptions
    stay inactive until paired encryption. A fresh-pairing store must coordinate
    saves with successful bond persistence, not just encryption completion.
    The provider owns the returned store beyond this session's borrowed use.
  */
  create-cccd-store host/central.Central link/central.Link database/attributes.Database owner/Owner? -> cccd.Store?:
    return null

  /** Supplies legacy advertising data for the configured database. */
  advertisement -> ByteArray: return #[2, 1, 6]

  /**
  How long a peripheral session advertises for a central, or null to
    advertise until one connects or the client closes the session.

  Unbounded by default. With $mixed-role-sessions an advertising session
    holds the shared host's setup, so central sessions would wait behind it;
    there the default is 60 seconds.
  */
  advertising-timeout -> Duration?:
    return mixed-role-sessions ? (Duration --s=60) : null

  /** Allows a transport-specific bound for ACL arriving before connection events. */
  early-acl-timeout -> Duration?: return null

  /**
  Enables fresh pairing with this IO capability, or disables it (null, the default).

  The values are the SMP IO capabilities: 0 display only, 1 display yes/no,
    2 keyboard only, 3 no input no output, 4 keyboard display. Secure
    Connections (Just Works, Numeric Comparison) and legacy Just Works are
    supported. Bond storage stays with $create-security-owner overrides.
  */
  pairing-io-capability -> int?: return null

  /** Requires authenticated pairing when the provider enables pairing. */
  require-authentication -> bool: return false

  /** Obtains local confirmation; overrides must use the device's trusted UI. */
  confirm-pairing number/int -> bool: return false

  /**
  Shows the six-digit Passkey Entry $passkey for the peer's user to type.

  Called when $pairing-io-capability has a display (0, 1 or 4) and the
    association makes this side the displaying one. The default prints it,
    which suits development on a serial console; a product overrides it.
  */
  display-passkey passkey/int -> none:
    print "BLE passkey: $(%06d passkey)"

  /**
  Returns the passkey the user typed, or null to give up.

  Called when $pairing-io-capability has a keyboard (2 or 4) and this side
    must type what the peer displays. The default gives up.
  */
  input-passkey -> int?: return null

  /**
  Creates the session's protocol owner before advertising starts.

  Overrides may load trusted bond records here and return a Central subclass
    whose on-connected hook installs a resumption key before early HCI events.
    Preserve the supplied receive bound and controller credit limits.
  */
  create-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    return central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count --phy-2m=info.phy-2m
        --accept-parameter-requests=accept-parameter-requests
        --early-acl-timeout=early-acl-timeout
        --receive-limit=receive-limit

  /**
  Selects security for the accepted link entirely inside the provider.

  The default pairs (without bonding) when $pairing-io-capability is set, and
    selects no security owner otherwise. A resumption override returns the
    owner already installed by its host's on-connected hook. No key material
    or security policy is accepted through application RPC.
  */
  create-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    capability := pairing-io-capability
    if capability == null: return null
    return security.Pairing host link --local-address=(link.local-random-address or info.address)
        --local-address-type=(link.local-random-address ? 1 : 0)
        --io-capability=capability
        --require-authentication=require-authentication
        --attempts=pairing-attempts
        --attempt-identity=(pairing-peer-identity link)

  /** Runs the security owner; the default runs pairing with $confirm-pairing. */
  run-security-owner owner/Owner -> none:
    if owner is not security.Pairing: throw "GATT_SECURITY_OWNER_UNSUPPORTED"
    (owner as security.Pairing).run
        --display=(:: display-passkey it)
        --input=(:: input-passkey)
        : | number/int | confirm-pairing number

  create-session client/int -> rpc.Session:
    return Session this client

  create-builder client/int name/string -> rpc.Session:
    return Session this client --name=name

  /** The largest database an application may ask for, in attributes (at most 512). */
  max-attributes -> int: return 256

  create-bounded-builder client/int name/string value-limit/int mtu-limit/int
      --attribute-limit/int=64 -> rpc.Session:
    if attribute-limit is not int or not 1 <= attribute-limit <= max-attributes: throw "INVALID_ARGUMENT"
    return Session this client --name=name --value-limit=value-limit --mtu-limit=mtu-limit
        --attribute-limit=attribute-limit

class Session extends rpc.Session:
  is-peripheral -> bool: return true

  provider_/Provider
  database_/attributes.Database
  advertisement_/ByteArray := #[]
  scan-response_/ByteArray := #[]
  interval_/int := 160
  started_/bool := false
  advertising-updates_/advertising-updates.Changes? := null
  handler-timeout_/Duration := Duration --s=1
  peer_/monitor.Latch ::= monitor.Latch
  pool_/shared.Host? := null
  controller_/hci.Controller? := null
  transport_/transport.Transport? := null
  host_/central.Central? := null
  link_/central.Link? := null
  server_/gatt.Server? := null
  operations_/operations.ClientOperations? := null
  indication_/gatt.Indication? := null
  indication-token_/int := 0
  submitting-indication_/bool := false
  worker_/Task? := null
  resources-released_/bool := false
  transport-cleanup-error_ := null
  pairing_/Owner? := null
  security-closed_/bool := false
  pairing-task_/Task? := null
  pairing-ended_/monitor.Latch ::= monitor.Latch

  constructor .provider_ client/int --name/string?=null --value-limit/int=20 --mtu-limit/int=23
      --attribute-limit/int=64:
    if name == null:
      database_ = provider_.create-database
    else:
      database_ = attributes.Database.with-defaults --name=name --caching --value-limit=value-limit
          --mtu-limit=mtu-limit
          --attribute-limit=attribute-limit
    if name == null:
      advertisement_ = provider_.advertisement.copy
      if advertisement_.size > 31: throw "INVALID_ARGUMENT"
    super provider_ client --value-limit=database_.value-limit
    if name == null: start_ advertisement_ #[]

  start_ advertisement/ByteArray response/ByteArray --interval/int=160 -> none:
    check-building_
    if advertisement.size > 31 or response.size > 31 or not 0x20 <= interval <= 0x4000:
      throw "INVALID_ARGUMENT"
    advertisement_ = advertisement.copy
    scan-response_ = response.copy
    advertising-updates_ = advertising-updates.Changes
    interval_ = interval
    started_ = true
    pool_ = provider_.reserve-peripheral-host
    try:
      start-worker_
    finally:
      if pool_ and not worker_:
        critical-do --no-respect-deadline:
          pool_.release
          pool_ = null

  start-worker_ -> none:
    worker_ = task --background::
      failure := "GATT_PEER_DISCONNECTED"
      try:
        error := catch: run_
        if error:
          failure = error.stringify
          if not peer_.has-value: peer_.set failure --exception
      finally:
        critical-do --no-respect-deadline:
          if advertising-updates_: advertising-updates_.stop
          // Callback cancellation can bypass the worker's ordinary catch.
          // Preserve an already-ended link's failure before closing requests.
          if failure == "GATT_PEER_DISCONNECTED" and link_ and link_.has-ended:
            link-error := catch: link_.wait-disconnected
            if link-error: failure = link-error.stringify
          requests.close --error=failure
          cleanup-error := release_
          if not peer_.has-value:
            peer_.set (cleanup-error ? cleanup-error.stringify : "GATT_REQUESTS_CLOSED") --exception
          join-error := catch:
            if pool_:
              if link_:
                disconnect-error := catch:
                  with-timeout timeouts.CLEANUP: link_.wait-disconnected
                if disconnect-error and not link_.has-ended: throw disconnect-error
            else if host_: host_.wait-closed
            else if controller_: controller_.wait-closed
            // Finish controller/link cleanup even after security's bounded
            // join expires, but do not release a reusable session or shared
            // lifetime while that old worker can still act on the controller.
            if pairing-task_ and not pairing-ended_.has-value:
              throw "GATT_SECURITY_CLEANUP_INCOMPLETE"
          if pool_:
            if transport-cleanup-error_ or join-error: pool_.fail
            release-error := catch: pool_.release
            join-error = join-error or release-error
          transport-cleanup-error_ = transport-cleanup-error_ or join-error or
              (controller_ and controller_.close-error)
          resources-released_ = transport-cleanup-error_ == null

  is-released -> bool:
    if not is-closed: return false
    // A failed worker creation may also have interrupted pool release. Only
    // successful release clears that reference; keep other outcomes unavailable.
    if worker_ == null: return pool_ == null
    return resources-released_ and (pairing-task_ == null or pairing-ended_.has-value)

  check-serving -> none:
    if not started_: throw "GATT_NOT_STARTED"

  check-building_ -> none:
    if started_: throw "GATT_DATABASE_SEALED"

  invoke index/int arguments/List -> any:
    if index == api.SET-HANDLER-TIMEOUT:
      check-building_
      if arguments.size != 1: throw "INVALID_ARGUMENT"
      duration/int := arguments[0]
      if not 1 <= duration <= 10_000_000: throw "INVALID_ARGUMENT"
      handler-timeout_ = Duration --us=duration
      requests.written-timeout = handler-timeout_
      return null
    if index == api.ADD-DESCRIPTOR:
      check-building_
      if arguments.size != 4: throw "INVALID_ARGUMENT"
      flags/int := arguments[2]
      if flags < 0 or flags & ~15 != 0: throw "INVALID_ARGUMENT"
      return database_.add-descriptor arguments[0] arguments[1]
          --read=((flags & 1) != 0)
          --write=((flags & 2) != 0)
          --value=arguments[3]
          --encrypted=((flags & 4) != 0)
          --authenticated=((flags & 8) != 0)
    if index == api.ADD-SERVICE:
      check-building_
      if arguments.size != 1 and arguments.size != 2: throw "INVALID_ARGUMENT"
      return database_.add-service arguments[0] --secondary=(arguments.size == 2 and arguments[1] == true)
    if index == api.INCLUDE-SERVICE:
      check-building_
      if arguments.size != 1 or arguments[0] is not int: throw "INVALID_ARGUMENT"
      return database_.include-service arguments[0]
    if index == api.ADD-CHARACTERISTIC:
      check-building_
      if arguments.size != 3: throw "INVALID_ARGUMENT"
      flags/int := arguments[1]
      if flags < 0 or flags & ~511 != 0: throw "INVALID_ARGUMENT"
      return database_.add-characteristic arguments[0]
          --read=((flags & 1) != 0)
          --write=((flags & 2) != 0)
          --write-command=((flags & 256) != 0)
          --notify=((flags & 4) != 0)
          --indicate=((flags & 128) != 0)
          --dynamic-read=((flags & 8) != 0)
          --validate-write=((flags & 16) != 0)
          --value=arguments[2]
          --encrypted=((flags & 32) != 0)
          --authenticated=((flags & 64) != 0)
    if index == api.START:
      if arguments.size != 2 and arguments.size != 3: throw "INVALID_ARGUMENT"
      start_ arguments[0] arguments[1] --interval=(arguments.size == 3 ? arguments[2] : 160)
      return null
    if index == api.PEER:
      check-serving
      if not arguments.is-empty: throw "INVALID_ARGUMENT"
      return peer_.get
    if index == api.PERIPHERAL-ADVERTISING-UPDATE:
      check-serving
      if arguments.size != 2: throw "INVALID_ARGUMENT"
      return advertising-updates_.update arguments[0] arguments[1]
    if link-operations.is-link-operation index:
      if not link_: throw "GATT_NOT_CONNECTED"
      return link-operations.link-operation host_ link_ index arguments --server=server_
    if operations.is-client-operation index:
      // A GATT client on the central's database, sharing the bearer.
      if not server_: throw "GATT_NOT_CONNECTED"
      if not operations_: operations_ = operations.ClientOperations server_.client
      return operations_.reply index arguments
    if index == api.REQUEST-SECURITY:
      if not arguments.is-empty: throw "INVALID_ARGUMENT"
      if not link_: throw "GATT_NOT_CONNECTED"
      // Pairing policy is the provider's: without an owner it does not pair.
      if not pairing_: throw "GATT_SECURITY_UNSUPPORTED"
      if pairing_ is not security.Pairing: throw "GATT_SECURITY_OWNER_UNSUPPORTED"
      if not link_.encrypted:
        (pairing_ as security.Pairing).request-security
        // The provider's pairing run, already waiting as responder, pairs
        // with the central and ends; a failure ends the link.
        with-timeout timeouts.SECURITY: pairing-ended_.get
      return invoke api.SECURITY []
    if index == api.SECURITY:
      if not arguments.is-empty: throw "INVALID_ARGUMENT"
      if not link_: throw "GATT_NOT_CONNECTED"
      encrypted := link_.encrypted
      paired := link_.connected and pairing_ != null and pairing_.paired
      authenticated := encrypted and paired and pairing_.authenticated
      return [paired, encrypted, authenticated]
    if index == api.MTU:
      if not arguments.is-empty: throw "INVALID_ARGUMENT"
      if not server_: throw "GATT_NOT_CONNECTED"
      return server_.mtu
    if index == api.VALUE:
      if arguments.size != 1: throw "INVALID_ARGUMENT"
      return database_.value arguments[0]
    if index == api.SET-VALUE:
      if arguments.size != 2: throw "INVALID_ARGUMENT"
      database_.set-value arguments[0] arguments[1]
      return null
    if index == api.NOTIFY:
      if arguments.size != 1: throw "INVALID_ARGUMENT"
      if not server_: throw "GATT_NOT_CONNECTED"
      return server_.notify arguments[0] --no-truncate
    if index == api.NOTIFY-VALUES:
      if arguments.size != 2 or arguments[1] is not ByteArray: throw "INVALID_ARGUMENT"
      packed/ByteArray := arguments[1]
      if packed.size > 32 * 514: throw "INVALID_ARGUMENT"
      if not server_: throw "GATT_NOT_CONNECTED"
      sent := 0
      offset := 0
      while offset < packed.size:
        if offset + 2 > packed.size: throw "INVALID_ARGUMENT"
        length := io.LITTLE-ENDIAN.uint16 packed offset
        offset += 2
        if length > 512 or offset + length > packed.size: throw "INVALID_ARGUMENT"
        database_.set-value arguments[0] packed[offset..offset + length]
        offset += length
        if not (server_.notify arguments[0] --no-truncate): return sent
        sent++
      return sent
    if index == api.INDICATE:
      if arguments.size != 2: throw "INVALID_ARGUMENT"
      if not server_: throw "GATT_NOT_CONNECTED"
      if indication_ or submitting-indication_: throw "GATT_INDICATION_BUSY"
      submitting-indication_ = true
      try:
        indication_ = server_.indicate arguments[0]
            --timeout=(Duration --us=arguments[1])
            --no-truncate
        if not indication_: return null
        return ++indication-token_
      finally:
        submitting-indication_ = false
    if index == api.WAIT-INDICATION:
      if arguments.size != 1: throw "INVALID_ARGUMENT"
      if not indication_ or arguments[0] != indication-token_: throw "GATT_INDICATION_EXPIRED"
      receipt := indication_
      try:
        receipt.wait
        return null
      finally:
        if receipt.is-complete and indication_ == receipt: indication_ = null
    return super index arguments

  on-closed -> none:
    critical-do --no-respect-deadline:
      super
      if advertising-updates_: advertising-updates_.stop
      if worker_: worker_.cancel
      if not peer_.has-value: peer_.set "GATT_REQUESTS_CLOSED" --exception
      error := release_
      if error: throw error

  run_ -> none:
    if pool_:
      // Setup includes advertising for the central, bounded only as configured.
      with-timeout provider_.advertising-timeout:
        pool_.setup: | host/central.Central capabilities/hci.Capabilities |
          host_ = host
          accept_ capabilities
    else:
      transport_ = provider_.open-transport
      controller_ = hci.Controller transport_
      info := hci.initialize controller_ --receive-acl-packets=provider_.receive-acl-packets
      provider_.controller-ready transport_ controller_ info
      host_ = provider_.create-host controller_ info (max 65 database_.mtu-limit)
      accept_ info
    serve_

  accept_ info/hci.Capabilities -> none:
    link := host_.accept advertisement_ --interval=interval_ --scan-response=scan-response_ --timeout=provider_.advertising-timeout
        --local-random-address=provider_.local-random-address
        --updates=advertising-updates_
    link_ = link
    pairing_ = provider_.create-security-owner host_ link info
    store := provider_.create-cccd-store host_ link database_ pairing_
    server_ = gatt.Server host_ link database_ --pairing=pairing_ --handler-timeout=handler-timeout_ --cccd-store=store

  serve_ -> none:
    link := link_
    server_.request-parameters --interval=12
    try:
      if pairing_:
        started := monitor.Latch
        pairing-task_ = task --background::
          try:
            started.set true
            error := catch:
              provider_.run-security-owner pairing_
              server_.security-ready
            if error:
              // A provider hook may fail after encryption, for example while
              // persisting a candidate. Do not depend on client mailbox reads
              // or the custom owner's cleanup to terminate that failed link.
              critical-do --no-respect-deadline:
                requests.close --error=error.stringify
                try:
                  // The server owns security cleanup after construction. Its
                  // close finishes link cleanup even if the hook throws; keep
                  // the original security failure as the application error.
                  catch: server_.close
                finally:
                  host_.abort link --error=error
          finally:
            critical-do --no-respect-deadline: pairing-ended_.set true
        // The child enters run before yielding, so early buffered SMP is not
        // dispatched to an inactive owner when serving starts.
        started.get
      // A peer the controller resolved is reported by its identity (types 2, 3).
      identity := link.info.identity-address
      peer_.set (identity
          ? [identity.copy, link.info.identity-address-type + 2]
          : [link.info.address.copy, link.info.address-type])
      server_.serve-with-requests
          (: | read/attributes.ReadRequest | requests.read read)
          (: | write/attributes.WriteRequest | requests.validate write)
          (: | handle/int value/ByteArray | requests.written handle value)
    finally:
      critical-do --no-respect-deadline:
        if pairing-task_:
          pairing-task_.cancel
          with-timeout timeouts.JOIN: pairing-ended_.get

  release_ -> any:
    if pairing-task_: pairing-task_.cancel
    if operations_: operations_.cancel
    // Once constructed, the server owns security cleanup. Before that point,
    // close the installed owner once, even if its hook throws. A hook failure
    // must neither escape the background worker nor skip controller teardown.
    error := catch:
      if server_:
        server_.close
      else if pairing_ and not security-closed_:
        security-closed_ = true
        pairing_.close
    close-error := catch:
      if pool_:
        if link_ and link_.connected: host_.abort link_
      else if host_: host_.close
      else if controller_: controller_.close
      else if transport_: transport_.close
    // A later idempotent close cannot prove that a failed transport close
    // released ownership. Still let the worker join, but quarantine this slot.
    transport-cleanup-error_ = transport-cleanup-error_ or close-error
    if operations_: catch: operations_.wait-ended
    return error or transport-cleanup-error_

/**
Configures the extended command family for mixed roles and checks that the
  controller supports both establishment orders.
*/
configure-mixed-roles controller/hci.Controller info/hci.Capabilities -> none:
  bounded.configure controller info
  supported := states.read controller
  if not (supported.supports states.CONNECTABLE-ADVERTISING-WITH-CENTRAL) or
      not (supported.supports states.INITIATING-WITH-PERIPHERAL):
    throw "GATT_MIXED_CONTROLLER_UNSUPPORTED"
