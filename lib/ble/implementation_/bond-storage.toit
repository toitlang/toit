// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import encoding.hex
import monitor
import .bond show Candidate
import .bond-protection show Protection

/**
Protected storage of bond candidates in a raw record backend.

$Records is the backend interface: a namespaced byte store with read,
  write and remove (`bond-flash` implements it on device flash,
  `bond-revocation` wraps one with deletion markers). $Storage seals each
  $Candidate with $Protection before it reaches the backend and verifies
  every write and delete by reading back. `bond-table` builds its slot
  table on $Storage; providers normally use that table rather than this
  library directly.
*/

/** Raw record backend. Successful writes/removes must satisfy its durability policy. */
interface Records:
  /** Returns a stable namespace, distinct from other stores using the same key. */
  namespace -> ByteArray
  /** Returns owned bytes, or null only for an absent record. Corruption must throw. */
  read name/string -> ByteArray?
  write name/string bytes/ByteArray -> none
  remove name/string -> none
  close -> none

/**
Stores protected candidates without asserting completed bonding.

Owns the backend after successful construction. The trusted provider must have
  exclusive write ownership of its namespace. Operations serialize within this
  object; external writers are not coordinated. Slots are caller-chosen opaque
  identifiers of 1 through 32 bytes, bound into record authentication together
  with the backend namespace. No plaintext or storage key reaches the backend.

Read-back checks detect ignored writes/deletes; they do not establish power-loss
  durability beyond the backend's guarantees. A failed write may leave either
  old or new data. Never promote a candidate on that exception. Reopening and
  loading authenticates the surviving data but still does not prove peer delivery.
*/
class Storage:
  records_/Records
  protection_/Protection
  namespace_/ByteArray
  mutex_/monitor.Mutex ::= monitor.Mutex
  closed_/bool := false

  constructor .records_ key/ByteArray:
    namespace_ = records_.namespace.copy
    if not 1 <= namespace_.size <= 64: throw "INVALID_ARGUMENT"
    protection_ = Protection key

  /** Saves an encrypted candidate and verifies the exact bytes read back. */
  save slot/ByteArray candidate/Candidate -> none:
    mutex_.do:
      context := context_ slot
      name := name_ slot
      sealed := protection_.seal candidate --context=context
      records_.write name sealed.copy
      if (records_.read name) != sealed: throw "BLE_BOND_WRITE_NOT_VERIFIED"

  /** Loads a candidate; returns null only when no record exists. */
  load slot/ByteArray -> Candidate?:
    return mutex_.do:
      context := context_ slot
      bytes := records_.read (name_ slot)
      if bytes == null: return null
      return protection_.open bytes --context=context

  /** Deletes a candidate and verifies absence; does not revoke an active link. */
  remove slot/ByteArray -> none:
    mutex_.do:
      context_ slot
      name := name_ slot
      records_.remove name
      if (records_.read name) != null: throw "BLE_BOND_DELETE_NOT_VERIFIED"

  /** Releases the backend and the owned storage-key reference. */
  close -> none:
    critical-do --no-respect-deadline:
      mutex_.do:
        if closed_: return
        closed_ = true
        protection_.close
        records_.close

  context_ slot/ByteArray -> ByteArray:
    if closed_: throw "BLE_BOND_STORAGE_CLOSED"
    if not 1 <= slot.size <= 32: throw "INVALID_ARGUMENT"
    return #[namespace_.size] + namespace_ + slot

name_ slot/ByteArray -> string: return "candidate/$(hex.encode slot)"
