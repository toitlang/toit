// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import monitor

import .connection as connection
import .encryption as encryption
import .signaling as signaling
import .acl as acl
import .hci as hci
import .advertising-set as advertising-set
import .advertising-updates as advertising-updates
import .cancellation show checkpoint
import .timeouts as timeouts

/** A controller-reported failure to establish a connection. */
class ConnectionError:
  status/int

  constructor .status:

  stringify -> string: return "HCI_CONNECTION_FAILED status=$status"

/**
A connection that ended before its setup completed.

$reason is the controller's disconnection reason when one was reported (for
  example 0x3e, Connection Failed to be Established), otherwise null.
*/
class ConnectionLost:
  reason/int?

  constructor .reason:

  stringify -> string:
    return reason ? "HCI_CONNECTION_LOST reason=0x$(%02x reason)" : "HCI_CONNECTION_LOST"

/** A particular connection lifetime, distinct from its reusable HCI handle. */
class Link:
  info/connection.Completion
  local-random-address_/ByteArray? := null
  ended_/monitor.Latch ::= monitor.Latch
  connected_/bool := true
  encryption_/encryption.Change? := null
  encryption-required_/bool := false
  closing_/bool := false
  error_ := null
  reason_/int? := null
  credits_/acl.Credits
  reassembler_/acl.Reassembler
  inbox_/acl.Inbox ::= acl.Inbox
  send-mutex_/monitor.Mutex ::= monitor.Mutex
  encryption-key_/ByteArray? := null
  key-reply-pending_/bool := false
  key-reply-error_ := null
  encryption-pending_/monitor.Latch? := null
  encryption-observer_/monitor.Latch? := null
  parameter-pending_/monitor.Latch? := null
  parameter-worker_/bool := false
  peer-parameter-error_ := null
  peer-parameter-request_/ByteArray? := null
  peer-parameter-verdict_/int := 1
  parameters_/connection.Update := ?
  receive-owner_ := null
  receive-limit_/int
  peer-features_/ByteArray? := null
  features-latch_/monitor.Latch ::= monitor.Latch

  constructor .info --acl-count/int --receive-limit/int=65 --credit-pool/acl.ControllerCredits?=null:
    receive-limit_ = receive-limit
    parameters_ = connection.Update 0 info.handle info.interval info.latency info.supervision-timeout
    // Includes the 65-byte SMP public-key command so it can be rejected.
    reassembler_ = acl.Reassembler info.handle --limit=receive-limit
    credits_ = acl.Credits acl-count --pool=credit-pool

  /** Returns an owned local random-address snapshot, or null for public setup. */
  local-random-address -> ByteArray?: return local-random-address_ and local-random-address_.copy

  /** Returns the latest successfully applied parameters; $info is the initial snapshot. */
  parameters -> connection.Update: return parameters_

  /** Returns the last accepted peer request's failure, or null. */
  peer-parameter-error: return peer-parameter-error_

  /** Tests whether an accepted peer parameter request is still being applied. */
  peer-parameters-pending -> bool: return parameter-worker_

  /** Tests the controller's last successful encryption report on this live link. */
  encrypted -> bool:
    return connected and encryption_ != null and encryption_.status == 0 and encryption_.enabled

  /**
  Requires encryption for the remainder of this link's lifetime.

  May only be set after controller encryption succeeds. A later failure or
    disabled event aborts this link, waking queued transmissions. Irreversible.
  */
  require-encryption -> none:
    if not encrypted: throw "HCI_ENCRYPTION_NOT_ENABLED"
    encryption-required_ = true

  /** Returns the last encryption event, including a failure; null means none yet. */
  encryption-change -> encryption.Change?: return encryption_

  /**
  Waits for the first controller encryption result, or returns the latest result.

  Does not start encryption or grant security permissions. Link shutdown and
    key-reply failure wake waiters with an exception. The caller supplies any
    deadline. Canceled waiters leave at most one shared latch until a result or
    shutdown; later waiters can reuse it without losing an event.
  */
  wait-encryption-change -> encryption.Change:
    if key-reply-error_: throw key-reply-error_
    if not connected: throw "HCI_LINK_DISCONNECTED"
    if encryption_: return encryption_
    if not encryption-observer_: encryption-observer_ = monitor.Latch
    return encryption-observer_.get

  key-reply-pending -> bool: return key-reply-pending_
  key-reply-error: return key-reply-error_

  /** Returns the configured maximum reassembled L2CAP payload size. */
  receive-limit -> int: return receive-limit_

  /**
  Returns the peer's LE features once the exchange completed, otherwise null.

  Central-role links read them right after connection. Null also means the
    controller rejected the read or the peer failed the exchange.
  */
  peer-features -> ByteArray?: return peer-features_ and peer-features_.copy

  /**
  Waits for the feature exchange started at connection and returns its result.

  Throws when the link ends first. The caller supplies any deadline. Links
    that never started an exchange (peripheral role) return null immediately.
  */
  wait-peer-features -> ByteArray?:
    if not features-latch_.has-value: features-latch_.get
    return peer-features

  features-known_ bytes/ByteArray? -> none:
    peer-features_ = bytes
    if not features-latch_.has-value: features-latch_.set null

  /** Returns whether application traffic is allowed, excluding local shutdown. */
  connected -> bool: return connected_ and not closing_

  /** Returns the error that stopped this link, or null while it is usable. */
  error -> any: return error_

  /** Waits for a complete L2CAP PDU, or throws when the link ends. */
  receive --owner=null -> acl.Packet:
    if connected and owner != receive-owner_: throw "L2CAP_RECEIVE_OWNED"
    return inbox_.take

  /** Reserves the PDU stream for one upper-layer dispatcher. */
  claim-receive owner -> none:
    if not connected: throw "HCI_LINK_DISCONNECTED"
    if not owner: throw "INVALID_ARGUMENT"
    if receive-owner_: throw "L2CAP_RECEIVE_OWNED"
    receive-owner_ = owner

  receive-high-water -> int: return inbox_.high-water

  /** Tests whether disconnection or terminal controller failure ended this link. */
  has-ended -> bool: return ended_.has-value

  /** Waits for disconnection and returns the controller's reason code. */
  wait-disconnected -> int: return ended_.get

  stop_ error -> none:
    closing_ = true
    if not error_: error_ = error
    fail-procedures_ error
    receive-owner_ = null
    credits_.stop error
    reassembler_.clear
    inbox_.fail error

  end_ reason/int -> none:
    if not connected_: return
    connected_ = false
    // Record the reason before waking any waiter; the disconnection latch is
    // set last so that protocol readers observe the failed inbox first.
    reason_ = reason
    release_ "HCI_LINK_DISCONNECTED"
    ended_.set reason

  fail_ error -> none:
    critical-do --no-respect-deadline:
      if not connected_: return
      connected_ = false
      release_ error
      ended_.set error --exception

  fail-procedures_ error -> none:
    encryption-key_ = null
    if not features-latch_.has-value: features-latch_.set error --exception
    observer := encryption-observer_
    encryption-observer_ = null
    if observer: observer.set error --exception
    encryption-pending := encryption-pending_
    encryption-pending_ = null
    if encryption-pending: encryption-pending.set error --exception
    pending := parameter-pending_
    parameter-pending_ = null
    if pending: pending.set error --exception

  release_ error -> none:
    if not error_: error_ = error
    fail-procedures_ error
    receive-owner_ = null
    credits_.fail error
    reassembler_.clear
    inbox_.fail error

monitor Cleanup_:
  pending_/int := 0

  start -> none: pending_++
  done -> none: pending_--
  wait -> none: await: pending_ == 0

/**
Owns an initialized controller and a bounded set of LE connections.

Consumes the controller's non-advertising event stream exclusively. Scanning may
  use the controller's separate scan API. Close this owner deterministically.
  One long-lived task handles connection state, including unsolicited disconnects.
*/
class Central:
  controller_/hci.Controller
  reader_/Task? := null
  reader-ended_/monitor.Latch ::= monitor.Latch
  pending_/monitor.Latch? := null
  advertising-updates_/advertising-updates.Changes? := null
  links_/Map := {:}
  link-limit_/int
  acl-quota_/int
  accept-parameter-requests_/bool
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
      --link-limit/int=1 --acl-quota/int?=null --accept-parameter-requests/bool=false:
    accept-parameter-requests_ = accept-parameter-requests
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
  Starts SC encryption with a big-endian candidate LTK and awaits controller proof.

  Supports central-role links only, one pending operation per link. Command
    rejection preserves the previous state. Timeout/cancellation aborts the link
    to prevent a late completion from satisfying a later operation. This method
    does not assert MITM authentication or persist a bond. Connect/accept
    admission is held only during command submission; a queued command checks
    link identity again before enqueueing and declines a disconnected lifetime.
  */
  encrypt link/Link key/ByteArray --timeout/Duration=(Duration --s=30) -> none:
    if not (owns-link link): throw "HCI_INVALID_LINK"
    if link.info.role != 0: throw "HCI_ENCRYPT_REQUIRES_CENTRAL"
    if link.encryption-pending_: throw "HCI_ENCRYPTION_BUSY"
    if busy_ or security-submissions_ != 0: throw "HCI_CONNECTION_BUSY"
    if timeout.in-us <= 0: throw "INVALID_ARGUMENT"
    bytes := encryption.enable-parameters link.info.handle key
    pending := monitor.Latch
    link.encryption-pending_ = pending
    completed := false
    try:
      with-timeout timeout:
        // Start encryption only after the feature exchange begun at connection
        // has finished, as other hosts do. A resumed BlueZ peripheral tears the
        // link down when the LTK request arrives before its own feature read.
        link.wait-peer-features
        // Prevent handle reuse through new connect/accept procedures while
        // command serialization or the native transport can still block.
        error := catch: security-command_ link 0x2019 bytes --status-event
        if error:
          if error is hci.CommandError or error == "HCI_COMMAND_NOT_SENT": completed = true
          throw error
        result/encryption.Change := pending.get
        completed = true
        if result.status != 0: throw (encryption.Error result.status)
        if not result.enabled: throw "HCI_ENCRYPTION_NOT_ENABLED"
    finally:
      critical-do --no-respect-deadline:
        if link.encryption-pending_ == pending: link.encryption-pending_ = null
        if not completed and link.connected: abort link --error="HCI_ENCRYPTION_ABORTED"

  /** Installs an owned SC key for this peripheral link's zero-Rand/EDIV requests. */
  set-encryption-key link/Link key/ByteArray -> none:
    if not (owns-link link): throw "HCI_INVALID_LINK"
    if link.info.role != 1: throw "HCI_KEY_REQUIRES_PERIPHERAL"
    if key.size != 16: throw "INVALID_ARGUMENT"
    if link.key-reply-pending_: throw "HCI_KEY_REPLY_BUSY"
    link.encryption-key_ = key.copy

  /** Removes a peripheral link's key; link close also drops it automatically. */
  clear-encryption-key link/Link -> none:
    if not (owns-link link): throw "HCI_INVALID_LINK"
    if link.key-reply-pending_: throw "HCI_KEY_REPLY_BUSY"
    link.encryption-key_ = null

  security-command_ link/Link opcode/int bytes/ByteArray --status-event/bool=false -> ByteArray:
    return with-timeout timeouts.COMMAND:
      // Automatic key replies must progress while another connection procedure
      // is pending, including before an accepted link's advertising termination.
      // Serialize the command and block new admission during submission; the
      // checked enqueue still rejects this exact link if its lifetime ends.
      if not (owns-link link): throw "HCI_COMMAND_NOT_SENT"
      security-submissions_++
      try:
        return controller_.command-if opcode bytes --status-event=status-event: owns-link link
      finally:
        critical-do --no-respect-deadline: security-submissions_--

  reply-key_ link/Link request/encryption.KeyRequest -> none:
    if link.key-reply-pending_:
      abort link --error="HCI_DUPLICATE_KEY_REQUEST"
      return
    tracked := false
    started := false
    try:
      link.key-reply-pending_ = true
      link.key-reply-error_ = null
      key := request.secure-connections ? link.encryption-key_ : null
      opcode := key ? 0x201a : 0x201b
      bytes := key
          ? (encryption.reply-parameters link.info.handle key)
          : (encryption.negative-parameters link.info.handle)
      cleanup_.start
      tracked = true
      task --background --name="BLE key reply"::
        try:
          error := catch:
            result := security-command_ link opcode bytes
            if result != (encryption.negative-parameters link.info.handle):
              throw "HCI_MALFORMED_KEY_REPLY"
          if error:
            link.key-reply-error_ = error
            if link.connected: abort link --error=error
        finally:
          critical-do --no-respect-deadline:
            link.key-reply-pending_ = false
            cleanup_.done
      started = true
    finally:
      if not started:
        critical-do --no-respect-deadline:
          link.key-reply-pending_ = false
          if tracked: cleanup_.done
          if link.connected: abort link --error="HCI_KEY_REPLY_ABORTED"

  /**
  Updates a central-role link and waits for the controller's applied parameters.

  One update may be outstanding per link. The returned values can differ from
    the requested range. A command rejection leaves the link usable; timeout or
    cancellation aborts the link because a late completion cannot identify a new
    request. The default completion bound is 30 seconds.
  */
  update-parameters link/Link --interval-min/int --interval-max/int
      --latency/int=0 --supervision-timeout/int=400
      --timeout/Duration=(Duration --s=30) -> connection.Update:
    if not (owns-link link): throw "HCI_INVALID_LINK"
    if link.info.role != 0: throw "HCI_UPDATE_REQUIRES_CENTRAL"
    if timeout.in-us <= 0: throw "INVALID_ARGUMENT"
    bytes := connection.update-parameters link.info.handle
        --interval-min=interval-min
        --interval-max=interval-max
        --latency=latency
        --supervision-timeout=supervision-timeout
    if link.parameter-worker_: throw "HCI_PARAMETER_UPDATE_BUSY"
    return update-parameters_ link bytes timeout

  update-parameters_ link/Link bytes/ByteArray timeout/Duration -> connection.Update:
    if not (owns-link link): throw "HCI_INVALID_LINK"
    if link.parameter-pending_: throw "HCI_PARAMETER_UPDATE_BUSY"
    pending := monitor.Latch
    link.parameter-pending_ = pending
    completed := false
    try:
      return with-timeout timeout:
        error := catch: controller_.command 0x2013 bytes --status-event
        if error:
          if error is hci.CommandError: completed = true
          throw error
        result/connection.Update := pending.get
        completed = true
        if result.status != 0: throw (ConnectionError result.status)
        result
    finally:
      critical-do --no-respect-deadline:
        if link.parameter-pending_ == pending: link.parameter-pending_ = null
        if not completed and link.connected: abort link --error="HCI_PARAMETER_UPDATE_ABORTED"

  /**
  Handles an LE signaling PDU without waiting for parameter application.

  With the owner's explicit acceptance option, valid peripheral requests are
    accepted only while this link has no outstanding update. A single bounded
    worker submits the HCI command; applied state and failure are exposed on
    the link. Other requests retain the fixed-channel rejection policy.
  */
  handle-signaling link/Link bytes/ByteArray -> none:
    if not (owns-link link): throw "HCI_INVALID_LINK"
    // Core 6.3, Vol 3 Part A, 4: duplicate requests should receive the same
    // response. Keep only the last request, scoped to this connection lifetime.
    if link.peer-parameter-request_ == bytes:
      send link 5 #[0x13, bytes[1], 2, 0, link.peer-parameter-verdict_, 0]
      return
    request/signaling.ParameterRequest? := null
    if link.info.role == 0 and accept-parameter-requests_ and bytes.size <= 23:
      request = signaling.decode-parameter-request bytes
    // The public caller may reuse its buffer once this call returns.
    retained := request and bytes.copy
    if not request or link.info.role != 0 or not accept-parameter-requests_ or
        not request.valid or link.parameter-pending_ or link.parameter-worker_:
      response := signaling.response bytes --peripheral=(link.info.role == 1)
      if response:
        send link 5 response
        // Another request, including an unsupported one, supersedes the
        // saved request. Ignored responses do not change this state.
        link.peer-parameter-request_ = retained
        link.peer-parameter-verdict_ = 1
      return
    parameters := connection.update-parameters link.info.handle
        --interval-min=request.interval-min
        --interval-max=request.interval-max
        --latency=request.latency
        --supervision-timeout=request.supervision-timeout
    tracked := false
    started := false
    try:
      link.parameter-worker_ = true
      link.peer-parameter-error_ = null
      cleanup_.start
      tracked = true
      with-timeout timeouts.SEND: send link 5 #[0x13, request.identifier, 2, 0, 0, 0]
      link.peer-parameter-request_ = retained
      link.peer-parameter-verdict_ = 0
      task --background --name="BLE peer parameters"::
        try:
          error := catch: update-parameters_ link parameters (Duration --s=30)
          if error: link.peer-parameter-error_ = error
        finally:
          critical-do --no-respect-deadline:
            link.parameter-worker_ = false
            cleanup_.done
      started = true
    finally:
      if not started:
        critical-do --no-respect-deadline:
          link.parameter-worker_ = false
          if tracked: cleanup_.done
          if link.connected: abort link --error="HCI_PARAMETER_UPDATE_ABORTED"

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

  /**
  Completes connection setup with the LE feature exchange on a central link.

  Every mainstream host reads remote features right after connection, and
    peers rely on that ordering: a BlueZ peripheral, for example, drops SMP
    and ATT traffic that arrives before its own side of the exchange has
    finished. The exchange therefore belongs to connection setup: $connect
    returns only after LE Read Remote Features Complete, within the caller's
    connect deadline. A controller rejection or a failed exchange leaves the
    features unknown without failing the connection. Interruption disconnects
    the new link before unwinding.
  */
  read-features_ link/Link -> none:
    ready := false
    try:
      // A cancelled task skips this classification; cleanup then disconnects
      // the link, so the abandoned command's outcome no longer matters.
      error := catch:
        controller_.command 0x2016 (connection.features-parameters link.info.handle) --status-event
      if error:
        if not (error is hci.CommandError): throw error
        link.features-known_ null
      checkpoint
      error = catch: link.wait-peer-features
      // An ended link is reported by the caller as a lost connection.
      if error and link.connected: throw error
      ready = true
    finally:
      if not ready and link.connected:
        cleanup-error := catch:
          disconnect_ link
        if cleanup-error: fail_ cleanup-error

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
      --timeout/Duration=(Duration --s=30) --local-random-address/ByteArray?=null
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
