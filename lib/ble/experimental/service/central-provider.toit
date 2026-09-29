// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import monitor
import ..att as att
import ..central as central
import ..gatt as gatt
import ..hci as hci
import ..transport as transport
import ..pairing-attempts as retry
import ..security-owner show Owner
import .api as api
import .link-operations as link-operations
import .provider as rpc
import .scanning-provider as scanning-provider
import .shared-host as shared
import ..timeouts as timeouts

/** Provides scanning and bounded central-role GATT connections. */
abstract class Provider extends scanning-provider.Provider implements shared.Factory:
  pool_/shared.Host? := null
  attempts_/retry.Attempts? := null
  constructor:
    super

  /**
  Selects controller-to-host ACL credits for connection sessions; zero disables.

  Overrides must reserve native ingress slots for control events and select a
    controller that supports 1024-byte host buffers. The setting belongs to the
    provider, not application RPC. Enabled credits cannot be combined with the
    optional early-ACL workaround. Scanning-only sessions do not use ACL credits.
  */
  receive-acl-packets -> int: return 0

  capabilities -> List: return [api.CAP-ADVERTISING | api.CAP-SCAN | api.CAP-CONTINUOUS-SCAN | api.CAP-GATT-CENTRAL, 60_000_000, 512, 517, central-session-limit]

  /** Selects a central session's local random address, or null for public. */
  central-local-random-address info/hci.Capabilities -> ByteArray?: return null

  /** Returns the shared retry history for fresh pairing across client sessions. */
  pairing-attempts -> retry.Attempts:
    if not attempts_: attempts_ = retry.Attempts
    return attempts_

  /**
  Selects the typed identity used for retry admission.

  Overrides must resolve known private peers to their stable identity. The
    default uses the typed on-air address and cannot correlate unknown RPAs.
  */
  pairing-peer-identity link/central.Link -> ByteArray:
    return #[link.info.address-type] + link.info.address

  /** Selects provider-owned central security; null keeps the link unbonded. */
  create-central-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?: return null

  /**
  Establishes the selected security before exposing the connection through RPC.

  Overrides run pairing or bond resumption and any required storage/UI work.
    This runs in the connection task, with ATT dispatch already active. A
    successful return must leave the selected owner paired and encrypted.
  */
  run-central-security-owner owner/Owner -> none:
    throw "GATT_CENTRAL_SECURITY_UNSUPPORTED"

  /** Creates a protocol owner with provider-selected controller limits. */
  create-central-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    return central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count --phy-2m=info.phy-2m
        --receive-limit=receive-limit
        --link-limit=central-session-limit

  /**
  Creates the shared host using the existing central policy by default.

  A future mixed-role provider must explicitly choose an early security hook
    that handles both roles. Admission remains central-only at present.
  */
  create-shared-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    return create-central-host controller info receive-limit

  // Called synchronously before a connection task starts. Reservations include
  // pending setup and cleanup, so neither can escape the configured limit.
  reserve-pool_ -> shared.Host?:
    if central-session-limit == 1: return null
    return reserve-shared-host

  /**
  Retains the provider's common controller lifetime before starting a worker.

  The caller must already hold an admitted session slot and release this
    reference after all setup, protocol and link cleanup has finished.
  */
  reserve-shared-host -> shared.Host:
    if not pool_ or pool_.released:
      pool_ = shared.Host this --receive-acl-packets=receive-acl-packets
    pool_.retain
    return pool_

  create-connection client/int arguments/List -> rpc.Session:
    if arguments.size != 4: throw "INVALID_ARGUMENT"
    address/ByteArray := arguments[0]
    type/int := arguments[1]
    timeout/int := arguments[2]
    mtu/int := arguments[3]
    if address.size != 6 or not 0 <= type <= 1 or not 1 <= timeout <= 60_000_000 or not 23 <= mtu <= 517:
      throw "INVALID_ARGUMENT"
    return ConnectionSession this client address.copy type timeout mtu

class ConnectionSession extends rpc.Session:
  pool_/shared.Host? := null
  attempts_/retry.Attempts? := null
  controller_/hci.Controller? := null
  transport_/transport.Transport? := null
  host_/central.Central? := null
  client_/att.Client? := null
  security_/Owner? := null
  link_/central.Link? := null
  worker_/Task? := null
  ready_/monitor.Latch ::= monitor.Latch
  ended_/monitor.Latch ::= monitor.Latch
  released_/bool := false
  cleanup-error_ := null
  subscriptions_/Map ::= {:}
  next-subscription_/int := 0

  constructor provider/Provider client/int address/ByteArray type/int timeout/int mtu/int:
    super provider client --value-limit=512
    try:
      pool_ = provider.reserve-pool_
      start-worker_ provider address type timeout mtu
    finally:
      if not worker_:
        critical-do --no-respect-deadline:
          try:
            if pool_:
              pool_.release
              pool_ = null
          finally:
            // A failed constructor cannot return this registered RPC handle.
            close

  start-worker_ provider/Provider address/ByteArray type/int timeout/int mtu/int -> none:
    worker_ = task --background::
      error := null
      try:
        error = catch:
          if pool_:
            with-timeout (Duration --us=timeout):
              pool_.setup: | host/central.Central info/hci.Capabilities |
                host_ = host
                connect_ provider info address type timeout mtu
          else:
            transport_ = provider.open-transport
            controller_ = hci.Controller transport_
            info := hci.initialize controller_ --receive-acl-packets=provider.receive-acl-packets
            provider.controller-ready transport_ info
            host_ = provider.create-central-host controller_ info (max 65 mtu)
            connect_ provider info address type timeout mtu
          link_.wait-disconnected
      finally:
        critical-do --no-respect-deadline:
          if not ready_.has-value: ready_.set (error ? error.stringify : "GATT_CONNECTION_CLOSED") --exception
          security-error := null
          close-error := null
          cleanup-error_ = catch:
            subscriptions_.values.do: | subscription/Subscription_ | subscription.cancel
            // ATT owns security after construction and finishes protocol
            // cleanup before reporting a hook error. Before construction,
            // release the installed owner directly. Either way, still join
            // the link, readers and controller before freeing the reservation.
            security-error = catch:
              if client_: client_.close
              else if security_: security_.close
            if not client_ and pool_ and link_ and link_.connected: host_.abort link_
            if not pool_:
              close-error = catch:
                if host_: host_.close
                else if controller_: controller_.close
                else if transport_: transport_.close
            if client_: client_.wait-closed
            subscriptions_.values.do: | subscription/Subscription_ | subscription.wait-ended
            if pool_:
              if link_:
                failure := catch:
                  with-timeout timeouts.CLEANUP: link_.wait-disconnected
                // A latched controller failure is a completed link lifetime.
                // Only an unfinished wait is a cleanup failure; the pool still
                // joins the failed controller before releasing its last slot.
                if failure and not link_.has-ended: throw failure
            else:
              if host_: host_.wait-closed
              else if controller_: controller_.wait-closed
          if pool_:
            if cleanup-error_: pool_.fail
            release-error := catch: pool_.release
            cleanup-error_ = cleanup-error_ or release-error
          cleanup-error_ = cleanup-error_ or close-error or (controller_ and controller_.close-error)
          released_ = cleanup-error_ == null
          // A reported hook failure does not strand a fully joined protocol
          // lifetime or terminate an otherwise healthy shared controller.
          cleanup-error_ = cleanup-error_ or security-error
          ended_.set true

  connect_ provider/Provider info/hci.Capabilities address/ByteArray type/int timeout/int mtu/int:
    link := host_.connect address --address-type=type --timeout=(Duration --us=timeout)
        --local-random-address=(provider.central-local-random-address info)
    link_ = link
    security_ = provider.create-central-security-owner host_ link info
    client_ = att.Client host_ link --mtu-limit=mtu --pairing=security_
    // Exchange the MTU first, as any GATT client does (Core Vol 3 Part G
    // 4.3.1). The peer's ATT response also proves that its host finished
    // connection setup; a BlueZ peripheral, for example, tears the link down
    // when an LTK request or Pairing Request arrives before that point.
    if security_ or mtu > 23: client_.exchange-mtu
    // The host asks for the 2M PHY on connecting; report the link as it
    // ends up rather than as it started.
    link.wait-phy-settled (Duration --s=1)
    if security_:
      provider.run-central-security-owner security_
      if not security_.paired or not security_.encrypted: throw "GATT_CENTRAL_SECURITY_NOT_READY"
    ready_.set [link.info.address.copy, link.info.address-type, client_.mtu]

  is-central -> bool: return true

  is-released -> bool: return is-closed and ended_.has-value and released_

  on-closed -> none:
    super
    if worker_: worker_.cancel

  invoke index/int arguments/List -> any:
    if index == api.CENTRAL-STOP:
      if not arguments.is-empty: throw "INVALID_ARGUMENT"
      failure := null
      try:
        if not pool_ and link_ and link_.connected:
          // The owner bounds the command and the completion event itself.
          failure = catch: host_.disconnect link_
      finally:
        if worker_ and not ended_.has-value: worker_.cancel
        critical-do --no-respect-deadline:
          with-timeout timeouts.WORKER: ended_.get
      if cleanup-error_: throw cleanup-error_.stringify
      if failure: throw failure.stringify
      return null
    if index == api.CENTRAL-READY:
      if not arguments.is-empty: throw "INVALID_ARGUMENT"
      return ready_.get
    ready_.get
    if link-operations.is-link-operation index:
      return link-operations.link-operation host_ link_ index arguments
    result := null
    error := catch: result = operation_ index arguments
    if error is att.AttributeError: return [false, error.request, error.handle, error.code]
    if error: throw error.stringify
    return [true, result]

  operation_ index/int arguments/List --revision/int?=null:
    if index == api.SECURITY:
      if not arguments.is-empty: throw "INVALID_ARGUMENT"
      encrypted := link_.encrypted
      paired := link_.connected and security_ != null and security_.paired
      authenticated := encrypted and paired and security_.authenticated
      return [paired, encrypted, authenticated]
    if index == api.CENTRAL-REVISION:
      if not arguments.is-empty: throw "INVALID_ARGUMENT"
      return client_.database-revision
    if index == api.CENTRAL-CHECKED:
      if arguments.size != 3: throw "INVALID_ARGUMENT"
      expected/int := arguments[0]
      operation/int := arguments[1]
      if not [api.CENTRAL-READ, api.CENTRAL-WRITE, api.CENTRAL-SERVICES,
              api.CENTRAL-CHARACTERISTICS, api.CENTRAL-DESCRIPTORS, api.CENTRAL-SUBSCRIBE,
              api.CENTRAL-WRITE-COMMAND].contains operation:
        throw "INVALID_ARGUMENT"
      client_.check-database-revision expected
      result := operation_ operation arguments[2] --revision=expected
      client_.check-database-revision expected
      return result
    if index == api.CENTRAL-MONITOR:
      if not arguments.is-empty: throw "INVALID_ARGUMENT"
      if subscriptions_.size == 8: throw "ATT_SUBSCRIPTION_LIMIT"
      token := ++next-subscription_
      subscriptions_[token] = Subscription_ client_ 0 0 true 8 --monitor-changes
      return token
    if index == api.CENTRAL-SUBSCRIBE:
      if arguments.size != 4: throw "INVALID_ARGUMENT"
      handle/int := arguments[0]
      cccd/int := arguments[1]
      indications/bool := arguments[2]
      limit/int := arguments[3]
      if not 1 <= handle < cccd <= 0xffff or not 1 <= limit <= 32: throw "INVALID_ARGUMENT"
      if subscriptions_.size == 8: throw "ATT_SUBSCRIPTION_LIMIT"
      token := ++next-subscription_
      subscriptions_[token] = Subscription_ client_ handle cccd indications limit --revision=revision
      return token
    if index == api.CENTRAL-SUBSCRIPTION-READY or index == api.CENTRAL-SUBSCRIPTION-NEXT or index == api.CENTRAL-UNSUBSCRIBE:
      if arguments.size != 1: throw "INVALID_ARGUMENT"
      subscription/Subscription_? := subscriptions_.get arguments[0]
      if not subscription: throw "ATT_SUBSCRIPTION_CLOSED"
      if index == api.CENTRAL-UNSUBSCRIBE:
        try:
          subscription.stop
        finally:
          if subscription.ended: subscriptions_.remove arguments[0]
        return null
      if index == api.CENTRAL-SUBSCRIPTION-READY:
        subscription.ready
        return null
      return subscription.receive
    if index == api.CENTRAL-READ:
      if arguments.size != 1: throw "INVALID_ARGUMENT"
      return client_.read-long arguments[0] --database-revision=revision
    if index == api.CENTRAL-WRITE:
      if arguments.size != 2: throw "INVALID_ARGUMENT"
      value/ByteArray := arguments[1]
      if value.size > 512: throw "INVALID_ARGUMENT"
      if value.size <= client_.mtu - 3: client_.write arguments[0] value --database-revision=revision
      else: client_.write-long arguments[0] value --database-revision=revision
      return null
    if index == api.CENTRAL-WRITE-COMMAND:
      if arguments.size != 2: throw "INVALID_ARGUMENT"
      client_.write-command arguments[0] arguments[1] --database-revision=revision
      return null
    if index == api.CENTRAL-SERVICES:
      if not arguments.is-empty: throw "INVALID_ARGUMENT"
      return (gatt.services client_).map: | s/gatt.Service | [s.start, s.end, s.uuid.copy]
    if index == api.CENTRAL-CHARACTERISTICS:
      if arguments.size != 2: throw "INVALID_ARGUMENT"
      return (gatt.characteristics client_ (gatt.Service arguments[0] arguments[1] #[])).map: | c/gatt.Characteristic |
        [c.declaration, c.handle, c.properties, c.uuid.copy, c.end]
    if index == api.CENTRAL-DESCRIPTORS:
      if arguments.size != 2: throw "INVALID_ARGUMENT"
      c := gatt.Characteristic 0 arguments[0] 0 #[]
      c.end = arguments[1]
      return (gatt.descriptors client_ c).map: | d/gatt.Descriptor | [d.handle, d.uuid.copy]
    throw "GATT_UNSUPPORTED_SERVICE_OPERATION"

// A provider task holds the cheap ATT subscription block for its RPC lifetime.
// Values stay in ATT's bounded managed queue; RPC does not add a second queue.
class Subscription_:
  ready_/monitor.Latch ::= monitor.Latch
  stop_/monitor.Latch ::= monitor.Latch
  ended_/monitor.Latch ::= monitor.Latch
  worker_/Task? := null
  stream_/att.Subscription? := null
  error_ := null

  constructor client/att.Client handle/int cccd/int indications/bool limit/int --monitor-changes/bool=false --revision/int?=null:
    worker_ = task --background::
      try:
        error_ = catch:
          if monitor-changes:
            gatt.with-service-changed client:
              ready_.set true
              stop_.get
          else:
            client.subscribe handle --cccd=cccd --indications=indications --queue-limit=limit
                --database-revision=revision: | stream/att.Subscription |
              stream_ = stream
              ready_.set true
              stop_.get
      finally:
        critical-do --no-respect-deadline:
          if not ready_.has-value: ready_.set (error_ or "ATT_SUBSCRIPTION_CLOSED") --exception
          ended_.set true

  ready -> none: ready_.get
  ended -> bool: return ended_.has-value
  receive -> ByteArray:
    ready
    if not stream_: throw "INVALID_ARGUMENT"
    // ATT returns an owned payload view; RPC copies slices into the message.
    return stream_.receive

  stop -> none:
    if not stop_.has-value: stop_.set true
    wait-ended
    if error_: throw error_

  cancel -> none:
    if worker_: worker_.cancel
  wait-ended -> none:
    with-timeout timeouts.WORKER: ended_.get
