// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import monitor

import ..attribute-server as attributes
import ..cccd-store as cccd
import ..central as central
import ..gatt-server as gatt
import ..hci as hci
import ..advertising-updates as advertising-updates
import ..security-owner show Owner
import ..transport as transport
import .api as api
import .provider as rpc
import .central-provider as central-provider
import .shared-host as shared

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
  reserve-peripheral-host -> shared.Host?: return null

  capabilities -> List: return [api.CAP-ADVERTISING | api.CAP-SCAN | api.CAP-CONTINUOUS-SCAN | api.CAP-GATT-PERIPHERAL | api.CAP-GATT-CENTRAL, 60_000_000, 512, 517, central-session-limit]

  /** Creates a fresh, bounded database for an application session. */
  create-database -> attributes.Database: return attributes.Database.with-defaults

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

  /** Allows a transport-specific bound for ACL arriving before connection events. */
  early-acl-timeout -> Duration?: return null

  /**
  Selects a local RPA or static random address for the next peripheral session.

  Returns six HCI-order bytes, or null to use the public address. Called once
    per session before advertising. The provider owns identity keys and address
    lifetime policy; application RPC never supplies this security context.
    Central validates and copies the result before submitting controller commands.
  */
  local-random-address -> ByteArray?: return null

  /**
  Returns null unless the explicit pairing-provider module is selected.

  Retained as a migration guard: enabling pairing through the ordinary base
    raises GATT_PAIRING_PROVIDER_REQUIRED instead of silently ignoring policy.
  */
  pairing-io-capability -> int?: return null

  /** Requires authenticated pairing when the provider enables pairing. */
  require-authentication -> bool: return false

  /** Obtains local confirmation; overrides must use the device's trusted UI. */
  confirm-pairing number/int -> bool: return false

  /**
  Creates the session's protocol owner before advertising starts.

  Overrides may load trusted bond records here and return a Central subclass
    whose on-connected hook installs a resumption key before early HCI events.
    Preserve the supplied receive bound and controller credit limits.
  */
  create-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    return central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --early-acl-timeout=early-acl-timeout
        --receive-limit=receive-limit

  /**
  Selects security for the accepted link entirely inside the provider.

  The default selects no security owner. Choose pairing-provider for fresh
    pairing. A resumption override
    returns the owner already installed by its host's on-connected hook.
    No key material or security policy is accepted through application RPC.
  */
  create-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    if pairing-io-capability != null: throw "GATT_PAIRING_PROVIDER_REQUIRED"
    return null

  /** Runs a custom security owner; overrides own its storage/UI policy. */
  run-security-owner owner/Owner -> none:
    throw "GATT_SECURITY_OWNER_UNSUPPORTED"

  create-session client/int -> rpc.Session:
    return Session this client

  create-builder client/int name/string -> rpc.Session:
    return Session this client --name=name

  create-bounded-builder client/int name/string value-limit/int mtu-limit/int -> rpc.Session:
    return Session this client --name=name --value-limit=value-limit --mtu-limit=mtu-limit

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

  constructor .provider_ client/int --name/string?=null --value-limit/int=20 --mtu-limit/int=23:
    database_ = name == null
        ? provider_.create-database
        : (attributes.Database.with-defaults --name=name --value-limit=value-limit --mtu-limit=mtu-limit)
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
                  with-timeout --ms=3_000: link_.wait-disconnected
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
      if arguments.size != 1: throw "INVALID_ARGUMENT"
      return database_.add-service arguments[0]
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
      with-timeout --ms=60_000:
        pool_.setup: | host/central.Central capabilities/hci.Capabilities |
          host_ = host
          accept_ capabilities
    else:
      transport_ = provider_.open-transport
      controller_ = hci.Controller transport_
      info := hci.initialize controller_ --receive-acl-packets=provider_.receive-acl-packets
      host_ = provider_.create-host controller_ info (max 65 database_.mtu-limit)
      accept_ info
    serve_

  accept_ info/hci.Capabilities -> none:
    link := host_.accept advertisement_ --interval=interval_ --scan-response=scan-response_ --timeout=(Duration --s=60)
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
      peer_.set [link.info.address.copy, link.info.address-type]
      server_.serve-with-requests
          (: | read/attributes.ReadRequest | requests.read read)
          (: | write/attributes.WriteRequest | requests.validate write)
          (: | handle/int value/ByteArray | requests.written handle value)
    finally:
      critical-do --no-respect-deadline:
        if pairing-task_:
          pairing-task_.cancel
          with-timeout --ms=3_000: pairing-ended_.get

  release_ -> any:
    if pairing-task_: pairing-task_.cancel
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
    return error or transport-cleanup-error_
