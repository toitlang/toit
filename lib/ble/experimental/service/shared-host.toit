// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import monitor
import ..central as central
import ..hci as hci
import ..transport as transport

/** Supplies one shared controller and its provider-owned early security policy. */
interface Factory:
  open-transport -> transport.Transport
  controller-ready radio/transport.Transport info/hci.Capabilities -> none
  create-shared-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central

/**
Owns one controller lifetime for reserved sessions, independently of their role.

The provider enforces admission bounds before calling $retain. Each session must
  stop its protocol tasks and finish link cleanup before calling $release, once.
  Its setup block must have returned before release. Only the final release
  closes and joins the controller. This class neither admits clients nor stores
  packet queues or application callbacks.
*/
class Host:
  factory_/Factory
  receive-acl-packets_/int
  setup_/monitor.Mutex ::= monitor.Mutex
  transport_/transport.Transport? := null
  controller_/hci.Controller? := null
  host_/central.Central? := null
  info_/hci.Capabilities? := null
  references_/int := 0
  released/bool := false
  closing_/bool := false
  error_ := null
  cleanup-error_ := null

  constructor .factory_ --receive-acl-packets/int=0:
    receive-acl-packets_ = receive-acl-packets

  /** Reserves a session before its worker starts. */
  retain -> none:
    if released or closing_ or error_ or (controller_ and controller_.close-error):
      throw "GATT_SERVICE_BUSY"
    references_++

  /**
  Initializes once and serializes session establishment using a scoped block.

  Established links continue exchanging traffic while another session sets up.
    The caller supplies its setup deadline, including waiting for this mutex.
  */
  setup [block] -> none:
    setup_.do:
      if error_: throw error_
      if references_ == 0 or closing_ or released: throw "GATT_SERVICE_BUSY"
      if controller_ and controller_.close-error: throw "GATT_SHARED_HOST_FAILED"
      if not host_:
        initialized := false
        try:
          error_ = catch:
            // Keep ownership of whatever opened if a later step fails.
            transport_ = factory_.open-transport
            controller_ = hci.Controller transport_
            info_ = hci.initialize controller_ --receive-acl-packets=receive-acl-packets_
            factory_.controller-ready transport_ info_
            host_ = factory_.create-shared-host controller_ info_ 517
          if error_: throw error_
          initialized = true
        finally:
          if not initialized:
            critical-do --no-respect-deadline:
              // Cancellation bypasses catch. Poison initialization before
              // another waiter can open a second transport over this lifetime.
              if not error_: error_ = "GATT_SHARED_HOST_FAILED"
              close-owner_
      block.call host_ info_

  /** Fails all sessions when shared state or cleanup becomes uncertain. */
  fail -> none:
    critical-do --no-respect-deadline:
      error_ = "GATT_SHARED_HOST_FAILED"
      close-owner_

  close-owner_ -> none:
    error := catch:
      if host_: host_.close
      else if controller_: controller_.close
      else if transport_: transport_.close
    cleanup-error_ = cleanup-error_ or error

  /** Releases one cleaned-up session and joins the last controller lifetime. */
  release -> none:
    if references_ == 0: throw "GATT_SHARED_HOST_NOT_RETAINED"
    references_--
    if references_ != 0: return
    closing_ = true
    critical-do --no-respect-deadline:
      close-owner_
      error := catch:
        if host_: host_.wait-closed
        else if controller_: controller_.wait-closed
      cleanup-error_ = cleanup-error_ or error or (controller_ and controller_.close-error)
      // Joining workers does not establish that a failed transport close
      // released controller ownership. Keep this lifetime quarantined.
      if cleanup-error_: throw cleanup-error_
      released = true
