// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor

import .connection as connection
import .hci as hci
import .advertising-set as advertising-set
import .advertising-updates as advertising-updates
import .cancellation show checkpoint
import .link
import .central show Central
import .timeouts as timeouts

/**
Connection establishment of a link owner ($Central): connect, accept and
  the advertising that accept runs.

Part of $Central; the abstract members are provided by it.
*/
abstract mixin LinkEstablishment_:
  // Provided by Central.
  abstract owns-link link/Link -> bool
  abstract controller_ -> hci.Controller
  abstract fail_ error --propagate-close-error/bool=false -> none
  abstract pending-local-random-address_ -> ByteArray?
  abstract pending-local-random-address_= value/ByteArray? -> none
  abstract pending_ -> monitor.Latch?
  abstract pending_= value/monitor.Latch? -> none
  abstract busy_ -> bool
  abstract busy_= value/bool -> none
  abstract security-submissions_ -> int
  abstract security-submissions_= value/int -> none
  abstract lost_ link/Link -> ConnectionLost
  abstract disconnect_ link/Link -> none
  abstract advertising-updates_ -> advertising-updates.Changes?
  abstract advertising-updates_= value/advertising-updates.Changes? -> none
  abstract links_ -> Map
  abstract link-limit_ -> int
  abstract check-open_ -> none
  abstract expected-role_ -> int
  abstract expected-role_= value/int -> none
  abstract request-phy_ link/Link -> none
  abstract read-features_ link/Link -> none
  abstract error_ -> any

  /**
  Connects to a public/random $address in HCI byte order.

  Copies $address before yielding. Completion is checked against that snapshot,
    even if another task changes the caller's array while connection is pending.

  Timeout or cancellation after submission cancels creation and consumes its
    completion event. A connection that wins the race is disconnected before
    unwinding. Cleanup has a separate three-second bound; failure closes the host.
    Task cancellation during address configuration or command submission waits
    for the command reply before cleanup. The caller's deadline and the command's
    own three-second bound still apply; a missing reply fails the controller.
  */
  connect address/ByteArray --address-type/int
      --timeout/Duration=(Duration --s=10) --local-random-address/ByteArray?=null -> Link:
    local := local-random-address and (connection.random-address local-random-address)
    parameters := encode-connection address --address-type=address-type
        --own-address-type=(local ? 1 : 0)
    peer := address.copy
    check-open_
    if busy_ or security-submissions_ != 0 or links_.size >= link-limit_: throw "HCI_CONNECTION_BUSY"
    // Allocate before publishing procedure ownership, outside the cleanup scope.
    pending := monitor.Latch
    expected-role_ = 0
    pending-local-random-address_ = local
    busy_ = true
    pending_ = pending
    submitted := false
    delivered := false
    status/hci.Pending? := null
    try:
      return with-timeout timeout:
        if local:
          controller_.command 0x2005 local
          checkpoint
        // Once submitted, creation must be cancelled on any exit, even one
        // that leaves before the controller's status arrives.
        status = controller_.submit connection-opcode parameters --status-event
        submitted = true
        status.wait
        checkpoint
        result := pending.get
        delivered = true
        if result is connection.Completion:
          throw (ConnectionError result.status)
        link/Link := result
        if link.info.address-type != address-type or link.info.address != peer:
          fail_ "HCI_UNEXPECTED_PEER"
          throw error_
        if not link.connected: throw (lost_ link)
        read-features_ link
        if not link.connected: throw (lost_ link)
        request-phy_ link
        return link
    finally:
      if submitted and not delivered:
        cleanup-error := catch:
          critical-do --no-respect-deadline:
            // The abandoned creation still settles with the engine; only a
            // creation the controller accepted has anything to cancel.
            created := true
            status-error := catch: status.wait
            if status-error:
              if not (status-error is hci.CommandError): throw status-error
              created = false
            if created:
              cancel-error := catch: controller_.command 0x200e
              if cancel-error:
                if not (cancel-error is hci.CommandError): throw cancel-error
                if cancel-error.status != 0x0c: throw cancel-error
              with-timeout timeouts.CLEANUP:
                result := pending.get
                if result is Link: disconnect_ result
        if cleanup-error: fail_ cleanup-error
      pending_ = null
      pending-local-random-address_ = null
      busy_ = false

  /** Supplies the connection command for this owner's controller command family. */
  connection-opcode -> int: return 0x200d

  /** Encodes the connection command for this owner's controller command family. */
  encode-connection address/ByteArray --address-type/int --own-address-type/int -> ByteArray:
    return connection.create-parameters address --address-type=address-type
        --own-address-type=own-address-type

  /** Decodes connection events for this owner's controller command family. */
  decode-connection-event packet/ByteArray --role/int -> connection.Completion?:
    return connection.decode-completion packet --role=role

  /** Consumes an additional controller procedure event before ordinary dispatch. */
  handle-controller-event packet/ByteArray -> bool: return false

  /**
  Reserves one peripheral establishment while a controller-specific $body runs.

  The body receives the connection-result latch. It must account for its whole
    advertising procedure before returning or unwinding, closing the owner if
    completion is uncertain. This scope disconnects a registered winning link
    on interruption before releasing setup and link capacity. It adds no task.
  */
  with-accept-procedure local/ByteArray? [body] --updates/advertising-updates.Changes?=null -> Link:
    check-open_
    if updates and updates.ended: throw "HCI_ADVERTISING_ENDED"
    if busy_ or security-submissions_ != 0 or links_.size >= link-limit_: throw "HCI_CONNECTION_BUSY"
    pending := monitor.Latch
    busy_ = true
    expected-role_ = 1
    pending-local-random-address_ = local
    pending_ = pending
    advertising-updates_ = updates
    delivered := false
    try:
      link/Link := body.call pending
      if not owns-link link: throw (lost_ link)
      checkpoint
      delivered = true
      return link
    finally:
      critical-do --no-respect-deadline:
        if updates: updates.stop
        advertising-updates_ = null
        if not delivered and pending.has-value:
          result := null
          error := catch: result = pending.get
          if not error and result is Link:
            cleanup-error := catch:
              disconnect_ result
            if cleanup-error: fail_ cleanup-error
        pending_ = null
        pending-local-random-address_ = null
        busy_ = false

  /**
  Advertises and accepts one peripheral-role connection.

  Uses legacy connectable advertising with public or host-selected random address.
    Advertising stops before returning the link. A rejected setup command leaves
    other links usable. Once the reader has registered a connection, interrupted setup
    disconnects that link with a separate three-second cleanup bound.
    Aborting while advertising is still pending closes the owner, preventing an
    orphaned late connection. Failed cleanup also closes the owner.
    The provisional Central name also covers this shared link-owner operation.

  Optional $updates belongs to this accept lifetime. This task applies its owned
    payloads after enablement. Connection creation ends update admission; a
    command already sent is settled before returning or reusing the owner.
  */
  accept advertisement/ByteArray --scan-response/ByteArray=#[] --interval/int=160
      --timeout/Duration?=(Duration --s=30) --local-random-address/ByteArray?=null
      --updates/advertising-updates.Changes?=null -> Link:
    local := local-random-address and (connection.random-address local-random-address)
    parameters := advertising-set.parameters --interval=interval --own-address-type=(local ? 1 : 0)
    data := advertising-set.data advertisement
    response := advertising-set.data scan-response
    check-open_
    if updates and updates.ended: throw "HCI_ADVERTISING_ENDED"
    if busy_ or security-submissions_ != 0 or links_.size >= link-limit_: throw "HCI_CONNECTION_BUSY"
    // Allocation failure must not leave the controller reserved by this call.
    pending := monitor.Latch
    busy_ = true
    expected-role_ = 1
    pending-local-random-address_ = local
    pending_ = pending
    completed := false
    // The engine owns the setup commands, so cleanup can settle whichever
    // one a cancelled caller abandoned instead of guessing its outcome.
    setup/hci.Pending? := null
    enable/hci.Pending? := null
    link/Link? := null
    advertising-updates_ = updates
    try:
      return with-timeout timeout:
        configuration := [
          [0x2006, parameters],
          [0x2008, data],
          [0x2009, response],
        ]
        if local: configuration.insert [0x2005, local] --at=0
        configuration.do: | command/List |
          checkpoint
          if updates and updates.ended: throw "HCI_ADVERTISING_UPDATE_ABORTED"
          // No connection can result before advertising is enabled.
          setup = controller_.submit command[0] command[1]
          setup.wait
        checkpoint
        enable = controller_.submit 0x200a #[1]
        enable.wait
        checkpoint
        if updates:
          updates.ready
          while not pending.has-value:
            request := updates.next
            if request: apply-advertising-update updates request
            if updates.ended and not pending.has-value: throw "HCI_ADVERTISING_UPDATE_ABORTED"
        result := pending.get
        if result is connection.Completion: throw (ConnectionError result.status)
        link = result
        if not link.connected: throw (lost_ link)
        // Legacy advertising already stopped when this connection was created
        // (Core Vol 4, Part E, 7.8.9); the disable command settles regardless
        // of the caller's cancellation.
        controller_.command 0x200a #[0]
        // Observe a deferred cancellation before transferring the link.
        checkpoint
        completed = true
        return link
    finally:
      critical-do --no-respect-deadline:
        if updates: updates.stop
        advertising-updates_ = null
        if not completed:
          if not link and pending.has-value:
            // The reader may have registered the connection while cancellation
            // prevented pending.get from delivering it to this task. Recover
            // that exact lifetime before deciding that advertising is ambiguous.
            result := null
            failure := catch: result = pending.get
            if not failure and result is Link: link = result
          if not link and (enable or setup):
            // Settle what this task abandoned. An enable the controller
            // accepted means advertising runs and must be stopped; the
            // disable's completion is ordered after any connection the
            // controller created meanwhile, so the latch is final after it.
            cleanup-error := catch:
              last := enable or setup
              error := catch: last.wait
              if error and not (error is hci.CommandError): throw error
              if enable and not error:
                controller_.command 0x200a #[0]
                if pending.has-value:
                  result := pending.get
                  if result is Link: link = result
            if cleanup-error: fail_ cleanup-error
          if link:
            cleanup-error := catch: disconnect_ link
            if cleanup-error: fail_ cleanup-error
        pending_ = null
        pending-local-random-address_ = null
        busy_ = false

  /** Applies owned payloads in the accept worker, settling commands before releasing its procedure. */
  apply-advertising-update changes/advertising-updates.Changes request/advertising-updates.Request -> none:
    data := advertising-set.data request.data
    response := advertising-set.data request.response
    error := catch:
      controller_.command-if 0x2008 data: not changes.ended
      // Observe cancellation before sending another command or reporting
      // success to the update caller.
      checkpoint
      if not changes.ended:
        controller_.command-if 0x2009 response: not changes.ended
        checkpoint
    if error:
      if error == "HCI_COMMAND_NOT_SENT" and changes.ended: return
      changes.stop --error=error.stringify
      throw error
    changes.complete request
