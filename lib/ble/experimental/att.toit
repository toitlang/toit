// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import monitor

import .central as central
import .hci as hci
import .signaling as signaling
import .security-owner as security

/** An ATT error response, retaining the failing request, handle, and status. */
class AttributeError:
  request/int
  handle/int
  code/int

  constructor .request .handle .code:

  security-required -> bool:
    return code == 5 or code == 8 or code == 12 or code == 15

  stringify -> string:
    suffix := security-required ? " (attribute requires security)" : ""
    return "ATT_ERROR request=$request handle=$handle code=$code$suffix"

/** A notification or indication with managed storage independent of future receives. */
class Notification:
  handle/int
  value/ByteArray
  indication/bool

  constructor .handle .value --indication/bool=false:
    this.indication = indication

/** Shared managed update capacity for one ATT client. */
monitor UpdateBudget_:
  queued_/int := 0

  queued -> int: return queued_

  add queue/UpdateQueue_ bytes/ByteArray -> none:
    // A scope may finish while a late packet is being dispatched to its queue.
    if queue.error_: return
    if queued_ == 32 or queue.bytes_.size == queue.limit_:
      queue.dropped++
      return
    queue.bytes_.add bytes
    queued_++

  take queue/UpdateQueue_ [prepare]:
    await: queue.error_ or queue.dropped != 0 or not queue.bytes_.is-empty
    if queue.error_: throw queue.error_
    if queue.dropped != 0: throw "ATT_NOTIFICATION_OVERFLOW"
    // Prepare the caller's result before consuming the queued packet. These
    // internal blocks only allocate/decode; they never suspend or call users.
    result := prepare.call queue.bytes_[0]
    queue.bytes_.remove --at=0
    queued_--
    return result

  fail queue/UpdateQueue_ error -> none:
    if queue.error_: return
    queue.error_ = error
    queued_ -= queue.bytes_.size
    queue.bytes_.clear

class UpdateQueue_:
  budget_/UpdateBudget_
  limit_/int
  bytes_/List := []
  error_ := null
  dropped/int := 0

  constructor .budget_ .limit_:
    if not 1 <= limit_ <= 32: throw "INVALID_ARGUMENT"

  add bytes/ByteArray -> none: budget_.add this bytes
  take [prepare]: return budget_.take this prepare
  fail error -> none: budget_.fail this error

/** A bounded notification stream valid only inside its subscription scope. */
class Subscription:
  handle/int
  packets_/UpdateQueue_
  cccd_/int := 0

  constructor .handle:
    packets_ = UpdateQueue_ UpdateBudget_ 32

  constructor.shared_ .handle .cccd_ budget/UpdateBudget_ limit/int:
    packets_ = UpdateQueue_ budget limit

  dropped -> int: return packets_.dropped

  receive -> ByteArray:
    if dropped != 0: throw "ATT_NOTIFICATION_OVERFLOW"
    value := packets_.take: | bytes/ByteArray | bytes[3..]
    if dropped != 0: throw "ATT_NOTIFICATION_OVERFLOW"
    return value

/**
An ATT client on the unenhanced fixed channel, initially using MTU 23.

Serializes requests while receiving notifications independently (Core 6.3 Vol 3
  Part F, 3.3.2). Owns the link's receive stream. Closing a live client or an
  ambiguous ATT failure aborts its link. Exclusive owners close as before;
  configured multi-link owners disconnect only the affected link.
  An ended link only closes this client, allowing the owner to reconnect.
  Discovery builds on $request.
*/
class Client:
  pairing_/security.Owner?
  host_/central.Central
  link_/central.Link
  mutex_/monitor.Mutex ::= monitor.Mutex
  pending_/monitor.Latch? := null
  opcode_/int := 0
  expected_/int := 0
  updates_/UpdateBudget_ ::= UpdateBudget_
  notifications_/UpdateQueue_
  reader_/Task? := null
  reader-ended_/monitor.Latch ::= monitor.Latch
  error_ := null
  subscriptions_/List ::= List 8
  cleanup-error_ := null
  mtu-limit_/int
  mtu_/int := 23
  mtu-started_/bool := false
  mtu-pending_/bool := false
  peer-mtu_/int? := null
  database-revision_/int := 0
  service-changed-handle_/int := 0
  service-changed-cccd_/int := 0

  constructor .host_ .link_ --mtu-limit/int=23 --pairing/security.Owner?=null:
    pairing_ = pairing
    if pairing and not (pairing.matches host_ link_): throw "SMP_WRONG_LINK"
    if not 23 <= mtu-limit <= 517 or mtu-limit > link_.receive-limit:
      throw "INVALID_ARGUMENT"
    mtu-limit_ = mtu-limit
    notifications_ = UpdateQueue_ updates_ 32
    if not (host_.owns-link link_): throw "HCI_INVALID_LINK"
    link_.claim-receive this
    reader_ = task --background --name="ATT receive"::
      try:
        error := catch: receive-loop_
        if error: fail_ error
      finally:
        critical-do --no-respect-deadline: reader-ended_.set true

  /** Returns the connection-local discovery revision. */
  database-revision -> int: return database-revision_

  /** Tests whether a discovery revision still belongs to this live database. */
  valid-database-revision revision/int -> bool:
    return not error_ and link_.connected and revision == database-revision_

  /**
  Rejects stale discovery work or a closed connection.

  A closed client or ended link reports its own error; only a live connection
    whose database revision moved reports GATT_DATABASE_CHANGED.
  */
  check-database-revision revision/int -> none:
    if revision != database-revision_: throw "GATT_DATABASE_CHANGED"
    if error_: throw error_
    if not link_.connected: throw (link_.error or "HCI_LINK_DISCONNECTED")

  /**
  Monitors a discovered Service Changed characteristic during $body.

  Invalidates the entire connection-local discovery revision before confirming
    each indication. Changes are processed directly by the reader, without a
    delivery queue or application callback. Entry and exit invalidate old records.
    Use GATT discovery to obtain the characteristic and $cccd. Only one monitor
    may be active. This does not provide persistent or bonded caching.
  */
  monitor-service-changed handle/int --cccd/int [body]:
    if not 1 <= handle < cccd <= 0xffff: throw "INVALID_ARGUMENT"
    if service-changed-handle_ != 0: throw "GATT_CHANGE_MONITOR_BUSY"
    try:
      service-changed-handle_ = handle
      service-changed-cccd_ = cccd
      database-revision_++
      return subscribe handle --cccd=cccd --indications: body.call
    finally:
      critical-do --no-respect-deadline:
        service-changed-handle_ = 0
        service-changed-cccd_ = 0
        database-revision_++

  /** Returns the effective ATT MTU. */
  mtu -> int: return mtu_

  /**
  Exchanges the configured receive MTU once, returning the effective minimum.

  A completed peer-initiated exchange is already sufficient. Repeated calls do
    not send another exchange. Request Not Supported leaves MTU at its default.
  */
  exchange-mtu --timeout/Duration=(Duration --s=3) -> int:
    return with-timeout timeout:
      mutex_.do:
        if error_: throw error_
        if mtu-started_ or peer-mtu_ != null: continue.do mtu_
        mtu-started_ = true
        mtu-pending_ = true
        try:
          error := catch: request_ (mtu-packet_ 2 mtu-limit_) 3
          if error and not (error is AttributeError and error.code == 6): throw error
        finally:
          mtu-pending_ = false
        mtu_

  /**
  Performs one ATT request, returning the entire response PDU.

  Copies $bytes before waiting for request serialization. Caller mutation cannot
    alter the transmitted PDU or the checks performed when its response arrives.

  With $database-revision, checks the revision after acquiring the request lock
    and before transmitting. A change during an ordinary request is reported
    after draining its wire response; the request is never retried automatically.
  */
  request bytes/ByteArray --response/int --database-revision/int?=null
      --timeout/Duration=(Duration --s=3) -> ByteArray:
    if bytes.is-empty or bytes.size > 517 or not 1 <= response <= 255:
      throw "INVALID_ARGUMENT"
    if bytes[0] == 2: throw "ATT_USE_EXCHANGE_MTU"
    snapshot := bytes.copy
    return with-timeout timeout:
      mutex_.do:
        if error_: throw error_
        if database-revision != null: check-database-revision database-revision
        request_ snapshot response

  // The caller holds mutex_ and supplies the operation deadline.
  request_ bytes/ByteArray response/int --database-revision/int?=null -> ByteArray:
    if error_: throw error_
    if database-revision != null: check-database-revision database-revision
    if bytes.size > mtu_: throw "INVALID_ARGUMENT"
    completed := false
    revision := database-revision_
    monitor-write := bytes.size == 5 and bytes[0] == 0x12 and
        (io.LITTLE-ENDIAN.uint16 bytes 1) == service-changed-cccd_
    try:
      pending := monitor.Latch
      pending_ = pending
      opcode_ = bytes[0]
      expected_ = response
      host_.send-checked link_ 4 bytes:
        if bytes[0] != 2 and not monitor-write: check-database-revision revision
      result/ByteArray := pending.get
      completed = true
      // Drain the wire response before reporting invalidation, preserving ATT
      // request ordering. MTU and the monitor's own CCCD are not cached values.
      if bytes[0] != 2 and not monitor-write:
        check-database-revision revision
      if result[0] == 1:
        throw (AttributeError result[1] (io.LITTLE-ENDIAN.uint16 result 2) result[4])
      return result
    finally:
      if not completed: fail_ "ATT_REQUEST_ABORTED"

  /** Reads at most MTU minus one bytes of an attribute value. */
  read handle/int --database-revision/int?=null -> ByteArray:
    result := request (handle-request_ 0x0a handle) --response=0x0b
        --database-revision=database-revision
    return result[1..]

  /**
  Reads a complete value into owned storage, bounded by $limit (at most 512).

  Uses Read Blob requests after a full first response. The peer can change its
    value between requests; this procedure does not provide a consistent snapshot
    of a concurrently changing attribute (Core 6.3 Vol 3 Part F, 3.4.4.5).
  */
  read-long handle/int --limit/int=512 --timeout/Duration=(Duration --s=30)
      --database-revision/int?=null -> ByteArray:
    if not 1 <= limit <= 512: throw "INVALID_ARGUMENT"
    return with-timeout timeout:
      mutex_.do:
        if error_: throw error_
        if database-revision != null: check-database-revision database-revision
        read-long_ handle limit database-revision_

  read-long_ handle/int limit/int revision/int -> ByteArray:
    result := ByteArray limit
    offset := 0
    part-limit := mtu_ - 1
    response := with-timeout --ms=3_000: request_ (handle-request_ 0x0a handle) 0x0b --database-revision=revision
    part := response[1..]
    while true:
      if offset + part.size > limit: throw "ATT_VALUE_TOO_LONG"
      result.replace offset part
      offset += part.size
      if part.size < part-limit: return result[0..offset].copy
      bytes := ByteArray 5
      bytes.replace 0 (handle-request_ 0x0c handle)
      io.LITTLE-ENDIAN.put-uint16 bytes 3 offset
      previous-limit := part-limit
      part-limit = mtu_ - 1
      error := catch:
        response = with-timeout --ms=3_000: request_ bytes 0x0d --database-revision=revision
        part = response[1..]
      if error:
        if error is AttributeError and error.handle == handle and error.code == 0x0b and
            mtu_ - 1 > previous-limit:
          // A peer exchange can make the whole fixed value fit in a normal
          // read while this operation is in progress. Restart at the larger MTU.
          offset = 0
          part-limit = mtu_ - 1
          response = with-timeout --ms=3_000: request_ (handle-request_ 0x0a handle) 0x0b --database-revision=revision
          part = response[1..]
          continue
        // Invalid Offset can terminate a long value. A fixed short attribute
        // exactly filling the first response may instead report Attribute Not Long.
        if error is AttributeError and error.handle == handle and
            (error.code == 7 or (offset == previous-limit and error.code == 0x0b)):
          return result[0..offset].copy
        throw error

  /** Writes up to MTU minus three bytes (at most 512), awaiting acknowledgement. */
  write handle/int value/ByteArray --database-revision/int?=null -> none:
    if value.size > (min 512 (mtu_ - 3)): throw "INVALID_ARGUMENT"
    bytes := ByteArray (3 + value.size)
    bytes.replace 0 (handle-request_ 0x12 handle)
    bytes.replace 3 value
    result := request bytes --response=0x13 --database-revision=database-revision
    if result.size != 1:
      fail_ "ATT_MALFORMED_RESPONSE"
      throw error_

  /**
  Submits an unacknowledged Write Command of at most MTU minus three bytes.

  Copies $value before waiting and checks the database revision at transport
    submission. Completion means transport acceptance, not peer receipt or
    permission approval. Values over 512 bytes are rejected; commands cannot
    be extended with Prepare Write. Cancellation during transmission aborts
    the link. A stale result may follow partial submission; never auto-replay.
  */
  write-command handle/int value/ByteArray --database-revision/int?=null -> none:
    if value.size > (min 512 (mtu_ - 3)): throw "INVALID_ARGUMENT"
    bytes := ByteArray (3 + value.size)
    bytes.replace 0 (handle-request_ 0x52 handle)
    bytes.replace 3 value
    with-timeout --ms=3_000:
      mutex_.do:
        if error_: throw error_
        if database-revision != null: check-database-revision database-revision
        revision := database-revision_
        host_.send-checked link_ 4 bytes: check-database-revision revision
        check-database-revision revision

  /**
  Writes at most 512 bytes using checked Prepare Write echoes and Execute Write.

  Owns a snapshot of $value and serializes the entire transaction against other
    requests. A rejected prepare or mismatched echo cancels the prepared queue.
    An interrupted in-flight request aborts the link because response ordering
    is ambiguous. Cleanup has its own three-second bound.
  */
  write-long handle/int value/ByteArray --timeout/Duration=(Duration --s=30)
      --database-revision/int?=null -> none:
    if not 1 <= handle <= 0xffff or value.size > 512 or timeout.in-us <= 0:
      throw "INVALID_ARGUMENT"
    snapshot := value.copy
    with-timeout timeout:
      mutex_.do:
        if error_: throw error_
        if database-revision != null: check-database-revision database-revision
        revision := database-revision_
        committed := false
        try:
          offset := 0
          // A zero-length prepare also allows replacing a value with empty data.
          while true:
            length := min (snapshot.size - offset) (mtu_ - 5)
            packet := ByteArray (5 + length)
            packet[0] = 0x16
            io.LITTLE-ENDIAN.put-uint16 packet 1 handle
            io.LITTLE-ENDIAN.put-uint16 packet 3 offset
            packet.replace 5 snapshot[offset..offset + length]
            response := with-timeout --ms=3_000: request_ packet 0x17 --database-revision=revision
            if response.size != packet.size or response[1..] != packet[1..]:
              throw "ATT_PREPARE_MISMATCH"
            offset += length
            if offset == snapshot.size: break
          response := with-timeout --ms=3_000: request_ #[0x18, 1] 0x19 --database-revision=revision
          if response != #[0x19]:
            fail_ "ATT_MALFORMED_RESPONSE"
            throw error_
          committed = true
        finally:
          if not committed and not error_:
            canceled := false
            try:
              critical-do --no-respect-deadline:
                response := with-timeout --ms=3_000: request_ #[0x18, 0] 0x19
                if response != #[0x19]: throw "ATT_MALFORMED_RESPONSE"
                canceled = true
            finally:
              if not canceled: fail_ "ATT_PREPARE_CANCEL_FAILED"

  dropped-notifications -> int: return notifications_.dropped

  /** Returns updates queued across all scoped and unscoped streams (at most 32). */
  queued-updates -> int: return updates_.queued

  /**
  Enables notifications or indications for $handle for the duration of $body.

  Provides a Subscription to the scoped block. Up to eight distinct handles/CCCDs
    may be subscribed concurrently. All exits invalidate only their own stream.
    Successful enable is paired with a bounded, cancellation-protected disable;
    failed cleanup aborts the link.
    With $indications, writes bit 1 of $cccd instead of bit 0. Indications are
    confirmed by the receive task; confirmation means protocol receipt, not
    application processing. Each stream holds at most $queue-limit packets
    (1–32, default 8), sharing a 32-packet budget with all other scoped streams
    and unscoped delivery. Overflow is reported by the affected stream, including
    a waiting receiver. Closing a scope discards its queued packets. Capacity is
    not reserved per stream; a full shared budget can overflow an empty stream.
    A monitored database change invalidates application streams. Their cleanup
    closes the link rather than disabling a potentially stale descriptor handle.
  */
  subscribe handle/int --cccd/int --indications/bool=false --queue-limit/int=8
      --database-revision/int?=null [body]:
    if not 1 <= handle < cccd <= 0xffff: throw "INVALID_ARGUMENT"
    if error_: throw error_
    if database-revision != null: check-database-revision database-revision
    revision := database-revision_
    if not 1 <= queue-limit <= 32: throw "INVALID_ARGUMENT"
    slot := -1
    subscriptions_.size.repeat: | index/int |
      existing/Subscription? := subscriptions_[index]
      if existing:
        if existing.handle == handle or existing.cccd_ == cccd: throw "ATT_SUBSCRIPTION_BUSY"
      else if slot == -1:
        slot = index
    if slot == -1: throw "ATT_SUBSCRIPTION_LIMIT"
    subscription := Subscription.shared_ handle cccd updates_ queue-limit
    enabled := false
    try:
      subscriptions_[slot] = subscription
      write cccd (indications ? #[2, 0] : #[1, 0]) --database-revision=revision
      enabled = true
      return body.call subscription
    finally: | is-exception _ |
      cleanup-error := catch:
        if enabled:
          if revision != database-revision_ and cccd != service-changed-cccd_:
            // The old descriptor may now designate something else. Disconnect
            // instead of writing to a stale handle during scope cleanup.
            close
            throw "GATT_DATABASE_CHANGED"
          disabled := false
          try:
            critical-do --no-respect-deadline:
              write cccd #[0, 0]
                  --database-revision=(cccd == service-changed-cccd_ ? null : revision)
            disabled = true
          finally:
            if not disabled: close
      critical-do --no-respect-deadline:
        subscriptions_[slot] = null
        subscription.packets_.fail "ATT_SUBSCRIPTION_CLOSED"
      // Cleanup still closes a link whose CCCD state is uncertain. Preserve
      // the scoped block's original failure or cancellation for its caller.
      if cleanup-error and not is-exception: throw cleanup-error

  /** Waits for a notification or indication, reporting any queue overflow explicitly. */
  receive-notification -> Notification:
    if notifications_.dropped != 0: throw "ATT_NOTIFICATION_OVERFLOW"
    notification := notifications_.take: | bytes/ByteArray |
      Notification (io.LITTLE-ENDIAN.uint16 bytes 1) bytes[3..]
          --indication=(bytes[0] == 0x1d)
    if notifications_.dropped != 0: throw "ATT_NOTIFICATION_OVERFLOW"
    return notification

  /** Waits for reader cleanup after close or failure, with a three-second bound. */
  wait-closed -> none:
    if not error_: throw "BLE_OWNER_NOT_CLOSED"
    with-timeout --ms=3_000:
      reader-ended_.get

  /**
  Closes protocol state and stops the reader, reporting a security cleanup error.

  Pending operations retain their original terminal error. A security close
    hook failure is retained and reported by subsequent close calls too.
  */
  close -> none:
    fail_ "ATT_CLOSED"
    reader := reader_
    reader_ = null
    if reader and reader != Task.current: reader.cancel
    if cleanup-error_: throw cleanup-error_

  fail_ error -> none:
    critical-do --no-respect-deadline:
      if error_: return
      error_ = error
      // A throwing provider hook must not strand a request, subscription or
      // link, or escape the receive task's failure handling.
      cleanup-error_ = catch:
        if pairing_: pairing_.close
      // An old link's teardown must not close a controller that can already be
      // establishing another connection, possibly with the same numeric handle.
      if link_.connected: host_.abort link_ --error=error
      pending := pending_
      pending_ = null
      if pending: pending.set error --exception
      notifications_.fail error
      subscriptions_.size.repeat: | slot/int |
        subscription/Subscription? := subscriptions_[slot]
        subscriptions_[slot] = null
        if subscription: subscription.packets_.fail error

  subscription-for_ handle/int -> Subscription?:
    subscriptions_.do: | subscription/Subscription? |
      if subscription and subscription.handle == handle: return subscription
    return null

  receive-loop_ -> none:
    while true:
      packet := link_.receive --owner=this
      if packet.channel == 5:
        host_.handle-signaling link_ packet.payload
        continue
      if packet.channel == 6:
        if pairing_:
          pairing_.receive packet.payload
          continue
        response := signaling.security-response packet.payload
        if response: host_.send link_ 6 response
        continue
      if packet.channel != 4: throw "ATT_UNHANDLED_L2CAP_CHANNEL"
      bytes := packet.payload
      if not bytes.is-empty and bytes[0] == 0x1d:
        // Confirm even an invalid handle/value, then discard it (3.4.7.2).
        // Do not take the request mutex: an indication can arrive while an
        // unrelated request is awaiting its response.
        changed := bytes.size >= 3 and service-changed-handle_ != 0 and
            (io.LITTLE-ENDIAN.uint16 bytes 1) == service-changed-handle_
        invalid-change := false
        if changed:
          database-revision_++
          invalid-change = bytes.size != 7
          if not invalid-change:
            first := io.LITTLE-ENDIAN.uint16 bytes 3
            last := io.LITTLE-ENDIAN.uint16 bytes 5
            invalid-change = not 1 <= first <= last <= 0xffff
        if changed:
          subscriptions_.do: | subscription/Subscription? |
            if subscription and subscription.handle != service-changed-handle_:
              subscription.packets_.fail "GATT_DATABASE_CHANGED"
        host_.send link_ 4 #[0x1e]
        if invalid-change: throw "GATT_INVALID_SERVICE_CHANGED"
        if changed: continue
        if bytes.size < 3 or bytes.size > (min mtu_ 515) or
            (io.LITTLE-ENDIAN.uint16 bytes 1) == 0: continue
      if bytes.is-empty or bytes.size > mtu_: throw "ATT_INVALID_PDU"
      opcode := bytes[0]
      if opcode == 2:
        if bytes.size != 3:
          host_.send link_ 4 #[1, 2, 0, 0, 4]
          continue
        peer := io.LITTLE-ENDIAN.uint16 bytes 1
        if peer-mtu_ != null and peer-mtu_ != peer: throw "ATT_MTU_CHANGED"
        host_.send link_ 4 (mtu-packet_ 3 mtu-limit_)
        peer-mtu_ = peer
        // Crossing exchanges keep default-sized responses until our own
        // exchange response arrives. This client sends no notifications itself.
        if not mtu-pending_: mtu_ = peer < 23 ? 23 : (min peer mtu-limit_)
        continue
      if opcode == 4 or opcode == 6 or opcode == 8 or opcode == 0x0a or
          opcode == 0x0c or opcode == 0x0e or opcode == 0x10 or opcode == 0x12 or
          opcode == 0x16 or opcode == 0x18 or opcode == 0x20:
        // We have no local attribute database yet; reject requests explicitly.
        host_.send link_ 4 #[1, opcode, 0, 0, 6]
        continue
      if opcode & 0x40 != 0: continue  // Unsupported commands have no response.
      if opcode == 0x1b or opcode == 0x1d:
        // Invalid notifications are ignored as required by section 3.4.7.1.
        if bytes.size < 3 or (io.LITTLE-ENDIAN.uint16 bytes 1) == 0: continue
        subscription := subscription-for_ (io.LITTLE-ENDIAN.uint16 bytes 1)
        if subscription:
          subscription.packets_.add bytes
        else:
          notifications_.add bytes
        continue
      pending := pending_
      if not pending: throw "ATT_UNEXPECTED_RESPONSE"
      if opcode == 1:
        if bytes.size != 5 or bytes[1] != opcode_ or bytes[4] == 0:
          throw "ATT_MALFORMED_RESPONSE"
      else if opcode != expected_:
        throw "ATT_UNEXPECTED_RESPONSE"
      if opcode == 3:
        if bytes.size != 3: throw "ATT_MALFORMED_RESPONSE"
        peer := io.LITTLE-ENDIAN.uint16 bytes 1
        if peer-mtu_ != null and peer-mtu_ != peer: throw "ATT_MTU_CHANGED"
        peer-mtu_ = peer
        mtu_ = peer < 23 ? 23 : (min peer mtu-limit_)
      if opcode_ == 2:
        mtu-pending_ = false
        if opcode == 1 and peer-mtu_ != null:
          mtu_ = peer-mtu_ < 23 ? 23 : (min peer-mtu_ mtu-limit_)
      pending_ = null
      pending.set bytes

mtu-packet_ opcode/int mtu/int -> ByteArray:
  result := #[opcode, 0, 0]
  io.LITTLE-ENDIAN.put-uint16 result 1 mtu
  return result

handle-request_ opcode/int handle/int -> ByteArray:
  if not 1 <= handle <= 0xffff: throw "INVALID_ARGUMENT"
  result := ByteArray 3
  result[0] = opcode
  io.LITTLE-ENDIAN.put-uint16 result 1 handle
  return result
