// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor

import .encryption as encryption
import .smp-legacy as legacy
import .hci as hci
import .link
import .central show Central
import .timeouts as timeouts

/**
Encryption and long term key handling of a link owner ($Central).

Part of $Central; the abstract members are provided by it.
*/
abstract mixin LinkSecurity_:
  // Provided by Central.
  abstract owns-link link/Link -> bool
  abstract controller_ -> hci.Controller
  abstract cleanup_ -> Cleanup_
  abstract abort link/Link --error="HCI_LINK_CLOSED" -> none
  abstract busy_ -> bool
  abstract busy_= value/bool -> none
  abstract security-submissions_ -> int
  abstract security-submissions_= value/int -> none

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
    encrypt_ link key null 0 timeout

  /**
  Starts encryption with a legacy bond's peer-distributed key, EDIV and Rand.

  Otherwise as $encrypt.
  */
  encrypt-legacy link/Link key/legacy.LegacyKey --timeout/Duration=(Duration --s=30) -> none:
    encrypt_ link key.key key.rand key.ediv timeout

  encrypt_ link/Link key/ByteArray random/ByteArray? ediv/int timeout/Duration -> none:
    if not (owns-link link): throw "HCI_INVALID_LINK"
    if link.info.role != 0: throw "HCI_ENCRYPT_REQUIRES_CENTRAL"
    if link.encryption-pending_: throw "HCI_ENCRYPTION_BUSY"
    if busy_ or security-submissions_ != 0: throw "HCI_CONNECTION_BUSY"
    if timeout.in-us <= 0: throw "INVALID_ARGUMENT"
    bytes := encryption.enable-parameters link.info.handle key --random=random --ediv=ediv
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

  /**
  Installs a legacy bond's locally distributed key for this peripheral link.

  The controller's request must carry the key's EDIV and Rand; any other
    request is answered negatively. Coexists with $set-encryption-key.
  */
  set-legacy-encryption-key link/Link key/legacy.LegacyKey -> none:
    if not (owns-link link): throw "HCI_INVALID_LINK"
    if link.info.role != 1: throw "HCI_KEY_REQUIRES_PERIPHERAL"
    if link.key-reply-pending_: throw "HCI_KEY_REPLY_BUSY"
    link.legacy-key_ = key

  /** Removes a peripheral link's keys; link close also drops them automatically. */
  clear-encryption-key link/Link -> none:
    if not (owns-link link): throw "HCI_INVALID_LINK"
    if link.key-reply-pending_: throw "HCI_KEY_REPLY_BUSY"
    link.encryption-key_ = null
    link.legacy-key_ = null

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
      legacy-key := link.legacy-key_
      if not key and legacy-key and legacy-key.ediv == request.ediv and legacy-key.rand == request.random:
        key = legacy-key.key
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
