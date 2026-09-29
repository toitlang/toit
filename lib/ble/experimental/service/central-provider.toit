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
import .gatt-client-operations as operations
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

  /**
  Whether central-role links apply a peripheral's valid connection parameter
    request (L2CAP Connection Parameter Update Request).

  True by default, as in other hosts; the request is applied with LE
    Connection Update and bounded like any other update.
  */
  accept-parameter-requests -> bool: return true

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
        --accept-parameter-requests=accept-parameter-requests
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
    if central-session-limit == 1 and not mixed-role-sessions: return null
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
    if address.size != 6 or not 0 <= type <= 3 or not 1 <= timeout <= 60_000_000 or not 23 <= mtu <= 517:
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
  operations_/operations.ClientOperations? := null

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
            provider.controller-ready transport_ controller_ info
            host_ = provider.create-central-host controller_ info (max 65 mtu)
            connect_ provider info address type timeout mtu
          link_.wait-disconnected
      finally:
        critical-do --no-respect-deadline:
          if not ready_.has-value: ready_.set (error ? error.stringify : "GATT_CONNECTION_CLOSED") --exception
          security-error := null
          close-error := null
          cleanup-error_ = catch:
            if operations_: operations_.cancel
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
            if operations_: operations_.wait-ended
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
    operations_ = operations.ClientOperations client_
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
    return operations_.invoke index arguments --revision=revision
