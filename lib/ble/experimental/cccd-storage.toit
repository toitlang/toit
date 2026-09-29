// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import crypto
import crypto.aes
import monitor
import .bond show Candidate
import .bond-storage show Records
import .cccd-store as cccd

HEADER_ ::= #[0x54, 0x43, 0x43, 1]

/**
Stores one protected CCCD configuration per bond slot.

Owns the backend after successful construction and requires exclusive mutation of
  its cccd/ record names. Each configuration authenticates the backend namespace,
  slot, exact candidate material and provider-owned database revision. A different
  context is an error, never an absent record or permission to overwrite it.
  The bond registry must clear a slot before reuse, even with identical keys.

The independent 32-byte storage key must remain protected outside this backend.
  Each write uses a random 96-bit GCM nonce; use fewer than 2^32 writes per key
  across instances/restarts. Encryption does not prevent rollback or deletion.
  Read-back verifies bytes, not durability beyond the Records implementation.
  Failure after a mutation starts quarantines that slot until explicit removal
  succeeds or the provider applies a recovery policy. Reopening is not recovery.
*/
class Storage:
  records_/Records
  key_/ByteArray? := ?
  namespace_/ByteArray
  mutex_/monitor.Mutex ::= monitor.Mutex
  failed_/Set := {}

  constructor .records_ key/ByteArray:
    if key.size != 32: throw "INVALID_ARGUMENT"
    namespace_ = records_.namespace.copy
    if not 1 <= namespace_.size <= 64: throw "INVALID_ARGUMENT"
    key_ = key.copy

  /**
  Creates a borrowed store for a selected bond and exact database revision.

  Does not authenticate a live connection or track revocation by itself. Trusted
    callers must hold their bond's admission guard across load/save, and revoke
    this use before removing or reusing the slot. The registry supplies that guard.
  */
  session slot/int candidate/Candidate --database-id/ByteArray -> cccd.Store:
    return Session_ this slot (context_ slot candidate database-id)

  context_ slot/int candidate/Candidate database-id/ByteArray -> ByteArray:
    check-slot_ slot
    if not 1 <= database-id.size <= 64: throw "INVALID_ARGUMENT"
    return "toit.ble.cccd".to-byte-array + HEADER_ + #[namespace_.size] + namespace_ +
        #[slot, database-id.size] + database-id + candidate.encode

  /**
  Migrates one record between two explicitly trusted database revisions.

  Calls $transform with the old owned snapshot or null, then seals its result
    under the new revision in one verified replacement. A record already valid
    under the new revision is left untouched, making an interrupted multi-peer
    migration restartable. A third revision or corrupt record is rejected.
    The caller must exclude live owners and hold the bond admission guard.
    The block must not reenter storage or its owning registry.
  */
  migrate slot/int candidate/Candidate --from-id/ByteArray --to-id/ByteArray [transform] -> none:
    if from-id == to-id: throw "INVALID_ARGUMENT"
    before := context_ slot candidate from-id
    after := context_ slot candidate to-id
    mutex_.do:
      check-usable_ slot
      migrate_ slot before after transform

  migrate_ slot/int before/ByteArray after/ByteArray [transform] -> none:
    current/ByteArray? := null
    error := catch: current = load-record_ slot after
    if not error and current: return
    if error and error != "BLE_INVALID_SEALED_CCCD": throw error
    previous := load-record_ slot before
    next/ByteArray := transform.call previous
    if not 2 <= next.size <= 1023: throw "INVALID_ARGUMENT"
    write-record_ slot after next.copy

  /** Deletes and verifies all configuration for this slot before bond reuse. */
  remove slot/int -> none:
    mutex_.do:
      check-slot_ slot
      succeeded := false
      try:
        records_.remove (name_ slot)
        if (records_.read (name_ slot)) != null: throw "BLE_CCCD_DELETE_NOT_VERIFIED"
        failed_.remove slot
        succeeded = true
      finally:
        if not succeeded: failed_.add slot

  /** Releases the backend and key reference without erasing GC copies. */
  close -> none:
    mutex_.do:
      if not key_: return
      key_ = null
      records_.close

  load_ slot/int context/ByteArray -> ByteArray?:
    return mutex_.do:
      check-usable_ slot
      load-record_ slot context

  load-record_ slot/int context/ByteArray -> ByteArray?:
    bytes := records_.read (name_ slot)
    if bytes == null: return null
    if not 34 <= bytes.size <= 290 or bytes[..4] != HEADER_:
      throw "BLE_INVALID_SEALED_CCCD"
    decryptor := aes.AesGcm.decryptor key_ bytes[4..16]
    try:
      plaintext/ByteArray? := null
      error := catch: plaintext = decryptor.decrypt bytes[16..] --authenticated-data=context
      if error == "INVALID_SIGNATURE": throw "BLE_INVALID_SEALED_CCCD"
      if error: throw error
      return plaintext
    finally:
      decryptor.close

  save_ slot/int context/ByteArray state/ByteArray -> none:
    if not 2 <= state.size <= 1023: throw "INVALID_ARGUMENT"
    state = state.copy
    mutex_.do:
      check-usable_ slot
      // Even callers that skipped load may not overwrite a different context.
      load-record_ slot context
      write-record_ slot context state

  write-record_ slot/int context/ByteArray state/ByteArray -> none:
    nonce := crypto.random --size=12
    encryptor := aes.AesGcm.encryptor key_ nonce
    sealed/ByteArray? := null
    try:
      sealed = HEADER_ + nonce + (encryptor.encrypt state --authenticated-data=context)
    finally:
      encryptor.close
    succeeded := false
    try:
      records_.write (name_ slot) sealed.copy
      if (records_.read (name_ slot)) != sealed: throw "BLE_CCCD_WRITE_NOT_VERIFIED"
      succeeded = true
    finally:
      if not succeeded: failed_.add slot

  check-slot_ slot/int -> none:
    if not key_: throw "BLE_CCCD_STORAGE_CLOSED"
    if not 0 <= slot < 255: throw "INVALID_ARGUMENT"

  check-usable_ slot/int -> none:
    check-slot_ slot
    if failed_.contains slot: throw "BLE_CCCD_STORAGE_FAILED"

class Session_ implements cccd.Store:
  storage_/Storage
  slot_/int
  context_/ByteArray
  constructor .storage_ .slot_ .context_:
  load -> ByteArray?: return storage_.load_ slot_ context_
  save state/ByteArray -> none: storage_.save_ slot_ context_ state

name_ slot/int -> string: return "cccd/$slot"
