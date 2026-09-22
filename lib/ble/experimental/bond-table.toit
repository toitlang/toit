// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor
import .bond show Candidate
import .bond-info show BondInfo
import .bond-storage show Records Storage

/**
A bounded table of protected bond candidates for a trusted provider.

Owns the backend after successful construction. Requires an exclusive namespace
  and a stable capacity of 1 through 255 slots across reopen. Changing capacity
  or importing opaque Storage slots requires an explicit migration. Slot numbers
  are zero-based. Enumeration authenticates records and returns only numbers,
  never secret material. No separate index needs a multi-record commit.

Adding never evicts an existing record or deduplicates peer identities. Explicit
  replacement and deletion retain Storage's read-back and durability semantics;
  ambiguous failures may have changed storage. Deletion does not revoke keys
  already loaded by an active connection. The provider owns that policy.
*/
class Table:
  capacity/int
  storage_/Storage
  mutex_/monitor.Mutex ::= monitor.Mutex
  closed_/bool := false
  epoch_/Epoch_ := Epoch_

  constructor records/Records key/ByteArray --.capacity:
    if not 1 <= capacity <= 255: throw "INVALID_ARGUMENT"
    storage_ = Storage records key

  /** Returns an authenticated snapshot of occupied slot numbers. */
  occupied -> List:
    return mutex_.do:
      check-open_
      result := []
      capacity.repeat: | slot/int |
        if storage_.load (name_ slot): result.add slot
      result

  /**
  Preloads all authenticated candidates for lookup without storage IO.

  Returns a secret-bearing snapshot for trusted provider code. Load it before
    accepting connections; the early connection hook can then select a bond
    without awaiting flash/RPC. Writes, deletion and table close invalidate prior snapshots before storage
    IO. Lookup on an invalidated snapshot throws BLE_STALE_BOND_SNAPSHOT, including
    after ambiguous failures. Candidates already extracted from entries and active connections
    still require provider-owned revocation.
  */
  snapshot -> Snapshot:
    return mutex_.do:
      check-open_
      if not epoch_.valid: epoch_ = Epoch_
      entries := []
      capacity.repeat: | slot/int |
        candidate := storage_.load (name_ slot)
        if candidate: entries.add (Entry.from-candidate_ slot candidate epoch_)
      Snapshot.from-entries_ entries epoch_

  /** Saves in the first empty slot; throws BLE_BOND_TABLE_FULL without eviction. */
  add candidate/Candidate -> int:
    return mutex_.do:
      check-open_
      capacity.repeat: | slot/int |
        if storage_.load (name_ slot): continue.repeat
        epoch_.valid = false
        storage_.save (name_ slot) candidate
        return slot
      throw "BLE_BOND_TABLE_FULL"

  /** Loads an owned candidate; returns null only for an absent record. */
  load slot/int -> Candidate?:
    return mutex_.do: storage_.load (name_ slot)

  /** Explicitly replaces the candidate in a slot, verifying the stored bytes. */
  save slot/int candidate/Candidate -> none:
    mutex_.do:
      name := name_ slot
      epoch_.valid = false
      storage_.save name candidate

  /** Deletes a slot and verifies absence without revoking active connections. */
  remove slot/int -> none:
    mutex_.do:
      name := name_ slot
      epoch_.valid = false
      storage_.remove name

  /** Releases the backend and owned storage-key reference. */
  close -> none:
    critical-do --no-respect-deadline:
      mutex_.do:
        if closed_: return
        closed_ = true
        epoch_.valid = false
        storage_.close

  check-open_ -> none:
    if closed_: throw "BLE_BOND_STORAGE_CLOSED"

  name_ slot/int -> ByteArray:
    check-open_
    if not 0 <= slot < capacity: throw "INVALID_ARGUMENT"
    return #[0x54, 0x42, 1, slot]

/** A table slot and guarded candidate access, for trusted provider code only. */
class Entry:
  slot/int
  candidate_/Candidate
  epoch_/Epoch_
  constructor.from-candidate_ .slot .candidate_ .epoch_:

  /**
  Returns an owned candidate while this entry remains current.

  Access after table mutation or close throws BLE_STALE_BOND_SNAPSHOT. A candidate
    previously returned remains owned data, not a revocable security lifetime.
  */
  candidate -> Candidate:
    if not epoch_.valid: throw "BLE_STALE_BOND_SNAPSHOT"
    return candidate_

/** A secret-bearing snapshot with bounded lookup and shared invalidation. */
class Snapshot:
  entries_/List
  epoch_/Epoch_
  constructor.from-entries_ .entries_ .epoch_:

  /** Returns owned public metadata in slot order, without exporting candidates. */
  bonds -> List:
    if not epoch_.valid: throw "BLE_STALE_BOND_SNAPSHOT"
    result := entries_.map: | entry/Entry |
      candidate := entry.candidate
      BondInfo entry.slot candidate.local.address candidate.local.address-type
          candidate.peer.address
          candidate.peer.address-type
          candidate.authenticated
    if not epoch_.valid: throw "BLE_STALE_BOND_SNAPSHOT"
    return result

  /**
  Selects a unique candidate matching both connection addresses, or returns null.

  Stable addresses and RPAs are supported. Multiple matches throw
    BLE_AMBIGUOUS_BOND, even when records contain the same key. Address resolution
    is not authentication; Resume must still verify connection context and
    encryption. Lookup does not suspend for storage or grant attribute access.
  */
  find -> Entry?
      --local-address/ByteArray --local-address-type/int
      --peer-address/ByteArray --peer-address-type/int:
    if local-address.size != 6 or peer-address.size != 6 or
        not 0 <= local-address-type <= 1 or not 0 <= peer-address-type <= 1:
      throw "INVALID_ARGUMENT"
    if not epoch_.valid: throw "BLE_STALE_BOND_SNAPSHOT"
    found/Entry? := null
    entries_.do: | entry/Entry |
      candidate := entry.candidate
      if not (candidate.local.matches local-address --address-type=local-address-type): continue.do
      if not (candidate.peer.matches peer-address --address-type=peer-address-type): continue.do
      if found: throw "BLE_AMBIGUOUS_BOND"
      found = entry
    if not epoch_.valid: throw "BLE_STALE_BOND_SNAPSHOT"
    return found

// Snapshots share only this token, not the table or its storage-key reference.
class Epoch_:
  valid/bool := true
