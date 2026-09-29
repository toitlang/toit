// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import monitor

import .connection as connection
import .encryption as encryption
import .acl as acl
import .hci as hci
import .advertising-updates as advertising-updates
import .link
import .timeouts as timeouts
import .central-security
import .central-control
import .central-establish

export Link ConnectionError ConnectionLost
/**
Owns an initialized controller and a bounded set of LE connections.

Consumes the controller's non-advertising event stream exclusively. Scanning may
  use the controller's separate scan API. Close this owner deterministically.
  One long-lived task handles connection state, including unsolicited disconnects.
*/
class Central extends Object with LinkSecurity_ LinkControl_ LinkEstablishment_:
  controller_/hci.Controller
  reader_/Task? := null
  reader-ended_/monitor.Latch ::= monitor.Latch
  pending_/monitor.Latch? := null
  advertising-updates_/advertising-updates.Changes? := null
  links_/Map := {:}
  link-limit_/int
  acl-quota_/int
  accept-parameter-requests_/bool
  phy-2m_/bool
  events_/hci.Packets ::= hci.Packets 32
  busy_/bool := false
  security-submissions_/int := 0
  error_ := null
  acl-length_/int
  credit-pool_/acl.ControllerCredits
  expected-role_/int := 0
  pending-local-random-address_/ByteArray? := null
  early-acl-timeout_/Duration?
  early-acl_/List := []
  early-acl-bytes_/int := 0
  early-acl-deadline_/int := 0
  early-acl-recovered/int := 0
  early-acl-max-delay-us/int := 0
  receive-limit_/int
  cleanup_/Cleanup_ ::= Cleanup_

  /**
  Constructs a link owner, optionally tolerating early ACL during connection setup.

  $early-acl-timeout is disabled by default. USB fixtures may enable it because
    event and ACL endpoints can complete out of order. At most four packets and
    512 bytes are held until a matching connection event, with no fixed sleep
    and no additional task. Expiry or invalid replay closes the owner.

  $link-limit defaults to one and bounds the live registry (at most sixteen).
    The controller may support fewer links. Creation/acceptance is serialized;
    existing links may transmit and receive while another is being established.
    $acl-quota defaults to the controller packet count divided by $link-limit,
    rounded up. Every account still shares the controller's aggregate budget.
    Per-link receive storage has the existing 32-PDU and $receive-limit bounds.
    At limits above one, link-local failures stop and disconnect that link.
    Controller/procedure ambiguity can still require closing the whole owner.

  $accept-parameter-requests is false by default. When enabled, valid peer
    L2CAP parameter requests on central-role links start at most one bounded
    worker per link. Busy requests are rejected. Applications can inspect
    Link.parameters and Link.peer-parameter-error for the controller outcome.
  */
  constructor .controller_ --acl-length/int=27 --acl-count/int=1
      --early-acl-timeout/Duration?=null --receive-limit/int=65
      --link-limit/int=1 --acl-quota/int?=null --accept-parameter-requests/bool=false
      --phy-2m/bool=false:
    accept-parameter-requests_ = accept-parameter-requests
    phy-2m_ = phy-2m
    if acl-length < 1 or acl-count < 1: throw "INVALID_ARGUMENT"
    if not 65 <= receive-limit <= 1024: throw "INVALID_ARGUMENT"
    receive-limit_ = receive-limit
    acl-length_ = min acl-length 1024
    if not 1 <= link-limit <= 16: throw "INVALID_ARGUMENT"
    link-limit_ = link-limit
    acl-quota_ = acl-quota or (max 1 ((acl-count + link-limit - 1) / link-limit))
    if not 1 <= acl-quota_ <= acl-count: throw "INVALID_ARGUMENT"
    credit-pool_ = acl.ControllerCredits acl-count --account-limit=link-limit
    if early-acl-timeout and not 1 <= early-acl-timeout.in-us <= 100_000:
      throw "INVALID_ARGUMENT"
    if early-acl-timeout and controller_.receive-flow-control:
      throw "HCI_RX_EARLY_ACL_UNSUPPORTED"
    early-acl-timeout_ = early-acl-timeout
    controller_.claim-events this
    reader_ = task --background --name="BLE central events"::
      try:
        error := catch: receive-loop_
        if error: fail_ error
      finally:
        critical-do --no-respect-deadline: reader-ended_.set true

  /**
  Configures a newly registered link before processing its next controller event.

  Runs in the controller receive task, before connect/accept returns. Overrides
    may install already-loaded keys, but must not wait, perform IO, or start
    synchronous HCI commands. Exceptions fail the controller owner. The default
    implementation does nothing. Use per-connection objects rather than storing
    application callbacks for packet dispatch.
  */
  on-connected link/Link -> none:

  /**
  Wakes extension-specific waiters when this owner fails or closes.

  Overrides must not wait, perform IO or send controller commands. May run
    repeatedly; $error is the owner's original terminal error. Exceptions are
    ignored so an extension cannot replace that error or prevent reader cleanup.
    The default implementation does nothing.
  */
  on-failure error -> none:

  /**
  Disconnects $link; an already-ended or locally stopping link is a harmless no-op.

  Use Link.wait-disconnected to await physical completion after local shutdown.
  */
  disconnect link/Link -> none:
    if not link.connected: return
    check-open_
    if (find-link_ link.info.handle) != link: throw "HCI_INVALID_LINK"
    if busy_ or security-submissions_ != 0: throw "HCI_CONNECTION_BUSY"
    busy_ = true
    completed := false
    try:
      disconnect_ link
      completed = true
    finally:
      busy_ = false
      if not completed: fail_ "HCI_DISCONNECT_ABORTED"

  /**
  Sends a complete L2CAP PDU, respecting controller credits and fragment order.

  Completion means transport submission, not peer receipt or ATT acknowledgement.
    An interrupted transmission aborts its link to avoid continuing a partial PDU.
  */
  send link/Link channel/int payload/ByteArray -> none:
    send-checked link channel payload: null

  /**
  Waits for outstanding packets to leave the controller's accounted buffers.

  Serializes with sends and bounds the wait to three seconds. Completion does
    not establish peer receipt; controllers may return credits after moving
    packets to other storage.
  */
  drain link/Link -> none:
    with-timeout timeouts.DRAIN:
      link.send-mutex_.do:
        check-open_
        if (find-link_ link.info.handle) != link or not link.connected: throw (link.error or "HCI_INVALID_LINK")
        link.credits_.drain

  /**
  Sends with a scoped validity check at each transport submission boundary.

  The $check block must not wait or perform IO; it throws if the operation is
    no longer valid. It runs after acquiring the link mutex and after credit
    or transport waits. A failure after reserving credits aborts the link,
    including a partially submitted PDU, so credit ownership stays bounded.
  */
  send-checked link/Link channel/int payload/ByteArray [check] -> none:
    if not 1 <= channel <= 0xffff or payload.size > 1024: throw "INVALID_ARGUMENT"
    with-timeout timeouts.SEND:
      link.send-mutex_.do:
        check-open_
        // A stopped link reports what stopped it, not a generic identity error.
        if (find-link_ link.info.handle) != link or not link.connected: throw (link.error or "HCI_INVALID_LINK")
        check.call
        completed := false
        try:
          acl.fragments-do link.info.handle channel payload --limit=acl-length_: | packet/ByteArray |
            link.credits_.take
            if not link.connected: throw "HCI_LINK_DISCONNECTED"
            controller_.send-acl packet:
              check.call
              link.connected
          completed = true
        finally:
          if not completed and link.connected: abort link --error="HCI_ACL_SEND_ABORTED"

  /**
  Stops a failed link and schedules bounded controller disconnection.

  A link-local failure ends that link only; the owner and its other links
    stay usable. Credits and the registry slot stay charged until
    Disconnection Complete. Failure to finish cleanup closes the controller
    because its resource state is then uncertain.
  */
  abort link/Link --error="HCI_LINK_CLOSED" -> none:
    if not error: throw "INVALID_ARGUMENT"
    if not link.connected: return
    check-open_
    if (find-link_ link.info.handle) != link: throw "HCI_INVALID_LINK"
    // Callers abort from cleanup, often in a cancelled task: the hand-over to
    // the cleanup task must not be interrupted (docs/ble/design.md, rule 5).
    critical-do --no-respect-deadline:
      started := false
      tracked := false
      try:
        link.stop_ error
        cleanup_.start
        tracked = true
        task --background --name="BLE link cleanup"::
          try:
            failure := catch:
              disconnect_ link
            if failure:
              fail_ failure
              close
          finally:
            critical-do --no-respect-deadline: cleanup_.done
        started = true
      finally:
        if not started:
          if tracked: cleanup_.done
          close

  /** Waits for other control events for the upper protocol layer. */
  receive -> ByteArray: return events_.take

  /** Waits for reader cleanup after close or failure, with a three-second bound. */
  wait-closed -> none:
    if not error_: throw "BLE_OWNER_NOT_CLOSED"
    with-timeout timeouts.JOIN:
      reader-ended_.get
      controller_.wait-closed
      cleanup_.wait

  /** Closes the owner, controller, and all pending operations. */
  close -> none:
    fail_ "HCI_CLOSED" --propagate-close-error

  disconnect_ link/Link -> none:
    if not link.connected_: return
    error := catch:
      controller_.command 0x0406 (connection.disconnect-parameters link.info.handle) --status-event
    // The peer may have disconnected while the command was in flight.
    if error and link.connected_: throw error
    // The engine bounds the command; this owner bounds the completion event.
    with-timeout timeouts.CLEANUP: link.wait-disconnected

  /** Describes a link that ended during setup, with its reason when known. */
  lost_ link/Link -> ConnectionLost:
    return ConnectionLost link.reason_

  find-link_ handle/int -> Link?:
    return links_.get handle --if-absent=: null

  /** Returns whether this owner has the given usable connection lifetime. */
  owns-link link/Link -> bool:
    return link.connected and (find-link_ link.info.handle) == link

  check-open_ -> none:
    if error_: throw error_

  fail_ error --propagate-close-error/bool=false -> none:
    critical-do --no-respect-deadline:
      try:
        if error_: return
        error_ = error
        if advertising-updates_: advertising-updates_.stop --error=error.stringify
        pending := pending_
        pending_ = null
        if pending: pending.set error --exception
        links_.do: | handle/int link/Link | link.fail_ error
        links_.clear
        clear-early-acl_
        events_.fail error
        close-error := catch: controller_.close
        // Keep protocol errors and cancellation primary during failure cleanup.
        if close-error and propagate-close-error: throw close-error
      finally:
        catch: on-failure error_
        reader := reader_
        reader_ = null
        if reader and reader != Task.current: reader.cancel

  receive-loop_ -> none:
    while true:
      packet/ByteArray := #[]
      if early-acl_.is-empty:
        packet = controller_.receive --owner=this
      else:
        remaining := early-acl-deadline_ - Time.monotonic-us
        if remaining <= 0: throw "HCI_EARLY_ACL_TIMEOUT"
        error := catch:
          packet = with-timeout (Duration --us=remaining): controller_.receive --owner=this
        if error == DEADLINE-EXCEEDED-ERROR: throw "HCI_EARLY_ACL_TIMEOUT"
        if error: throw error
      // A packet's state transitions complete or fail as a unit: closing this
      // owner cancels the reader, which must not leave a link half ended
      // (removed from the registry, its disconnection never published).
      critical-do --no-respect-deadline:
        controller_.consume packet --owner=this: process-packet_ packet

  process-packet_ packet/ByteArray -> none:
    if packet[0] == 2:
      link := find-link_ ((io.LITTLE-ENDIAN.uint16 packet 1) & 0x0fff)
      if not link:
        hold-early-acl_ packet
        return
      if link.closing_: return
      error := catch:
        pdu := link.reassembler_.accept packet
        if pdu: link.inbox_.add pdu
      if error: abort link --error=error
      return
    if (acl.completed-do packet: | handle/int count/int |
      link := find-link_ handle
      if not link: throw "HCI_UNEXPECTED_ACL_CREDITS"
      link.credits_.complete count):
      return
    if handle-controller-event packet: return
    completion := decode-connection-event packet --role=expected-role_
    if completion:
      pending := pending_
      if not pending or links_.size >= link-limit_: throw "HCI_UNEXPECTED_CONNECTION"
      if completion.status != 0:
        clear-early-acl_
        pending_ = null
        pending.set completion
        if advertising-updates_: advertising-updates_.stop
      else:
        if find-link_ completion.handle: throw "HCI_UNEXPECTED_CONNECTION"
        link := Link completion --acl-count=acl-quota_ --receive-limit=receive-limit_
            --credit-pool=credit-pool_
        link.local-random-address_ = pending-local-random-address_
        if completion.role != 0: link.features-known_ null
        links_[completion.handle] = link
        on-connected link
        if not early-acl_.is-empty:
          if Time.monotonic-us >= early-acl-deadline_: throw "HCI_EARLY_ACL_TIMEOUT"
          early-acl_.do: | held/ByteArray |
            // The reassembler checks the handle and fragment order before
            // any held bytes become visible to the new link's consumer.
            pdu := link.reassembler_.accept held
            if pdu: link.inbox_.add pdu
          early-acl-recovered += early-acl_.size
          delay := Time.monotonic-us - (early-acl-deadline_ - early-acl-timeout_.in-us)
          early-acl-max-delay-us = max early-acl-max-delay-us delay
          clear-early-acl_
        pending_ = null
        pending.set link
        if advertising-updates_: advertising-updates_.stop
      return
    features := connection.decode-features packet
    if features:
      // The exchange can complete with an error after the link already ended;
      // a completion for an unknown lifetime carries no information.
      link := find-link_ features.handle
      if link: link.features-known_ (features.status == 0 ? features.bytes : null)
      return
    phy := connection.decode-phy-update packet
    if phy:
      link := find-link_ phy.handle
      if link:
        link.phy_ = phy
        pending := link.phy-pending_
        link.phy-pending_ = null
        if pending: pending.set phy
      return
    phy-failure := connection.decode-phy-update-failure packet
    if phy-failure:
      link := find-link_ phy-failure[0]
      if link:
        pending := link.phy-pending_
        link.phy-pending_ = null
        if pending: pending.set (hci.CommandError hci.LE-SET-PHY phy-failure[1]) --exception
      return
    data-length := connection.decode-data-length packet
    if data-length:
      // A change for an ended lifetime carries no information.
      link := find-link_ data-length.handle
      if link: link.data-length_ = data-length
      return
    key-request := encryption.decode-key-request packet
    if key-request:
      link := find-link_ key-request.handle
      if not link or link.info.role != 1: throw "HCI_UNEXPECTED_KEY_REQUEST"
      if link.connected: reply-key_ link key-request
      return
    encryption-change := encryption.decode-change packet
    if encryption-change:
      link := find-link_ encryption-change.handle
      if not link: throw "HCI_UNEXPECTED_ENCRYPTION_EVENT"
      link.encryption_ = encryption-change
      if link.encryption-required_ and not link.encrypted:
        if link.connected: abort link --error="HCI_ENCRYPTION_LOST"
        return
      observer := link.encryption-observer_
      link.encryption-observer_ = null
      if observer: observer.set encryption-change
      pending := link.encryption-pending_
      link.encryption-pending_ = null
      if pending: pending.set encryption-change
      return
    update := connection.decode-update packet
    if update:
      link := find-link_ update.handle
      if not link: throw "HCI_UNEXPECTED_PARAMETER_UPDATE"
      if update.status == 0: link.parameters_ = update
      pending := link.parameter-pending_
      link.parameter-pending_ = null
      if pending: pending.set update
      return
    disconnected := connection.decode-disconnection packet
    if disconnected:
      link := find-link_ disconnected.handle
      if not link:
        throw "HCI_UNEXPECTED_DISCONNECTION"
      if disconnected.status != 0: throw (ConnectionError disconnected.status)
      links_.remove disconnected.handle
      link.end_ disconnected.reason
      return
    events_.add packet


  hold-early-acl_ packet/ByteArray -> none:
    if not early-acl-timeout_ or not busy_ or not pending_: throw "HCI_UNEXPECTED_ACL"
    if early-acl_.size >= 4 or early-acl-bytes_ + packet.size > 512:
      throw "HCI_EARLY_ACL_OVERFLOW"
    if early-acl_.is-empty:
      early-acl-deadline_ = Time.monotonic-us + early-acl-timeout_.in-us
    early-acl_.add packet
    early-acl-bytes_ += packet.size

  clear-early-acl_ -> none:
    early-acl_.clear
    early-acl-bytes_ = 0
    early-acl-deadline_ = 0
