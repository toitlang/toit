// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
One LE connection lifetime as seen by its owner (`central.Central`).

A `Link` is created by the owner's receive task on Connection Complete and
  ends on Disconnection Complete or owner failure; a reused HCI handle is a
  different `Link`. The owner's procedures (connect, accept, encryption,
  parameter updates) live in `central.toit`; this file holds the state a link
  carries between them and the errors that end one.
*/

import monitor

import .connection as connection
import .encryption as encryption
import .acl as acl

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
  data-length_/connection.DataLength? := null
  phy_/connection.Phy? := null
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

  /**
  Returns the link-layer payload lengths in effect, or null before any update.

  Controllers that support Data Length Extension negotiate these right after
    the connection; without it the link stays at 27 octets and this is null.
  */
  data-length -> connection.DataLength?: return data-length_

  /** Returns the PHYs in effect, or null while the link still uses the 1M PHY it started on. */
  phy -> connection.Phy?: return phy_

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
