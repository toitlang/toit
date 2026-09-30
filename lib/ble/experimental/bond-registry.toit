// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import monitor
import crypto
import .bond show Candidate
import .bond-table show Table Snapshot
import .bond-resume show Resume
import .security show Pairing
import .security-owner show Owner
import .central show Central Link
import .cccd-storage as configuration
import .cccd-store as cccd

/**
Bond admission for a trusted provider: which connections get which stored bond.

$Registry owns a $Table (and optionally the protected CCCD storage) and is
  the one place that creates security owners from it: $Registry.resume
  returns a $Resume owner for a connection whose peer is bonded, and
  $Registry.bond wraps a fresh $Pairing in a $Bonding owner that persists
  the resulting $Candidate before it grants encrypted access.
  $Registry.remove revokes a slot, closing its live owners first;
  $Registry.bonds and $Registry.inventory report metadata, and
  $Registry.cccd-store selects a bonded peer's CCCD store. A provider that
  keeps bonds creates one registry at startup and uses it from its
  `create-security-owner` hook; the bond administration service
  (`service/bond-admin-provider`) lists and removes bonds through it.
*/

/**
Coordinates trusted-provider bond admission and live security owners.

Owns the table after successful construction. All subsequent table mutations
  must go through this registry. Admission uses preloaded candidates and never
  waits for storage. Mutation pauses admission, and removal closes the selected
  slot's owners before storage IO. Other slots' live connections remain usable.

An ambiguous storage failure permanently stops admission through this instance;
  close it and apply explicit storage recovery before constructing another.
  This is an in-process policy, not a durable revocation journal or an authorized
  administration RPC API. Already extracted candidates and owners constructed
  outside this registry are not tracked. Callers still close each returned owner
  with its connection's lifetime.

An optional protected CCCD storage is also owned after successful construction.
  Configuration operations serialize with bond mutation. Removal and slot reuse
  clear that slot's configuration before changing the bond table. Selecting a
  database revision remains trusted provider policy. Fresh pairing uses $bond
  to attach persistence and revocation to the initial connection lifetime.
*/
class Registry:
  table_/Table
  configuration_/configuration.Storage?
  snapshot_/Snapshot? := ?
  owners_/List
  mutex_/monitor.Mutex ::= monitor.Mutex
  paused_/bool := false
  failed_/bool := false
  closed_/bool := false
  revision_/ByteArray := crypto.random --size=16

  constructor .table_ --owner-limit/int=1 --cccd-storage/configuration.Storage?=null:
    if not 1 <= owner-limit <= 16: throw "INVALID_ARGUMENT"
    configuration_ = cccd-storage
    owners_ = List owner-limit
    snapshot_ = table_.snapshot

  /**
  Selects and registers a resumption owner without suspending for storage.

  Rejects exhausted owner capacity with BLE_BOND_OWNER_LIMIT. With capacity
    available, a link already owned here is rejected with BLE_BOND_OWNER_EXISTS.
    Each tracked link has at most one owner.
  */
  resume host/Central link/Link --local-address/ByteArray
      --require-authentication/bool=false -> Resume:
    result/Resume? := null
    critical-do:
      index := owner-index_ host link
      entry := snapshot_.find --local-address=local-address
          --local-address-type=(link.local-random-address ? 1 : 0)
          --peer-address=link.info.address
          --peer-address-type=link.info.address-type
      if not entry: throw "BLE_BOND_NOT_FOUND"
      owner := TrackedResume_ this index entry.slot host link entry.candidate
          --local-address=local-address
          --require-authentication=require-authentication
      // Slots are preallocated: registration cannot allocate after a peripheral
      // constructor has installed its key.
      owners_[index] = owner
      result = owner
    return result

  /**
  Takes ownership of a fresh pairing object after successful registration.

  The supplied $pairing must belong to $host and $link and must not have been
    run or attached to ATT. Attach the returned owner instead, then call its run
    with the trusted confirmation block. It persists the candidate before
    exposing encrypted access. Already known peers require resumption or explicit
    removal, never silent replacement. Lookup uses the actual $local-address.
  */
  bond host/Central link/Link pairing/Pairing --local-address/ByteArray -> Bonding:
    result/Bonding? := null
    critical-do:
      index := owner-index_ host link
      if not (pairing.matches host link): throw "INVALID_ARGUMENT"
      if link.encryption-change != null: throw "BLE_BOND_REQUIRES_FRESH_LINK"
      entry := snapshot_.find --local-address=local-address
          --local-address-type=(link.local-random-address ? 1 : 0)
          --peer-address=link.info.address
          --peer-address-type=link.info.address-type
      if entry: throw "BLE_BOND_ALREADY_EXISTS"
      owner := Bonding.create_ this index pairing
      owners_[index] = owner
      result = owner
    return result

  owner-index_ host/Central link/Link -> int:
    check-open_
    if paused_: throw "BLE_BOND_ADMISSION_PAUSED"
    index := owners_.index-of null
    if index < 0: throw "BLE_BOND_OWNER_LIMIT"
    owners_.do: | owner/TrackedOwner_? |
      if owner and (owner.matches host link): throw "BLE_BOND_OWNER_EXISTS"
    return index

  admit_ owner/Bonding candidate/Candidate -> none:
    change_ null:
      require-owner_ owner --allow-paused
      // Two pending pairings may eventually disclose the same stable identity.
      // Recheck after distribution, under the mutation lock, before any write.
      entry := snapshot_.find --local-address=candidate.local.address
          --local-address-type=candidate.local.address-type
          --peer-address=candidate.peer.address
          --peer-address-type=candidate.peer.address-type
      if entry: throw "BLE_BOND_ALREADY_EXISTS"
      slot := add_ candidate
      // Close can run while storage IO is pending. Do not publish admission
      // to a lifetime that has ended, even if storage may already have changed.
      require-owner_ owner --allow-paused
      owner.bind_ slot candidate

  /** Adds without replacing or evicting any existing bond. */
  add candidate/Candidate -> int:
    return change_ null: add_ candidate

  add_ candidate/Candidate -> int:
    if not configuration_: return table_.add candidate
    occupied := snapshot_.bonds.map: it.slot
    table_.capacity.repeat: | slot/int |
      if occupied.contains slot: continue.repeat
      // Clear before insertion, even when the caller reuses identical keys.
      configuration_.remove slot
      added := table_.add candidate
      if added != slot: throw "BLE_BOND_SLOT_CHANGED"
      return added
    throw "BLE_BOND_TABLE_FULL"

  /**
  Selects protected CCCDs for a tracked security owner and database revision.

  Load/save hold the mutation lock and recheck the owner after storage IO.
    Revocation and slot reuse invalidate old stores; a caller cannot use a
    candidate extracted before revocation to resurrect subscription state.
    The registry owns its optional storage after successful construction.
    Before fresh pairing is durably admitted, load returns null and save fails.
    The bonding owner withholds encrypted access until admission completes, so
    ATT can keep receiving SMP identity distribution without waiting for storage.
  */
  cccd-store owner/Owner --database-id/ByteArray -> cccd.Store:
    return mutex_.do:
      tracked := require-owner_ owner
      if not configuration_: throw "BLE_CCCD_STORAGE_UNAVAILABLE"
      if not 1 <= database-id.size <= 64: throw "INVALID_ARGUMENT"
      GuardedConfiguration_ this tracked configuration_ database-id.copy

  /**
  Migrates all bonded configurations before admitting any live security owner.

  The trusted provider supplies distinct old/new revisions and a scoped snapshot
    transform, normally ConfigurationMigration.apply. Each peer's configuration
    and pending Service Changed flag commit together. Already migrated peers are
    skipped on restart; there is no atomic commit across the whole bond table.
    Do not advertise the new database until this method succeeds. Failures stop
    admission through this registry and require explicit backend recovery.
  */
  migrate-cccd --from-id/ByteArray --to-id/ByteArray [transform] -> none:
    if not 1 <= from-id.size <= 64 or not 1 <= to-id.size <= 64 or from-id == to-id:
      throw "INVALID_ARGUMENT"
    from-id = from-id.copy
    to-id = to-id.copy
    change_ null --require-idle:
      if not configuration_: throw "BLE_CCCD_STORAGE_UNAVAILABLE"
      snapshot_.bonds.do: | info |
        candidate := table_.load info.slot
        if not candidate: throw "BLE_BOND_NOT_FOUND"
        configuration_.migrate info.slot candidate --from-id=from-id --to-id=to-id transform

  /**
  Resolves connection addresses to an owned typed peer identity, or returns null.

  Uses the authenticated in-memory snapshot without storage IO or owner
    admission. Both local and peer context must match one unique bond. Returns
    seven bytes: address type followed by the six HCI-order identity bytes.
    Trusted providers may use this to share retry history across known RPAs;
    resolution does not authenticate a link or authorize fresh pairing.
    Ambiguity, paused mutation and failed/closed registries remain errors.
  */
  resolve-peer-identity -> ByteArray?
      --local-address/ByteArray --local-address-type/int
      --peer-address/ByteArray --peer-address-type/int:
    result/ByteArray? := null
    critical-do:
      check-open_
      if paused_: throw "BLE_BOND_ADMISSION_PAUSED"
      entry := snapshot_.find --local-address=local-address
          --local-address-type=local-address-type
          --peer-address=peer-address
          --peer-address-type=peer-address-type
      if not entry: return null
      identity := entry.candidate.peer
      result = #[identity.address-type] + identity.address
    return result

  /**
  Returns owned public bond metadata from the current authenticated snapshot.

  Waits for ongoing mutations and rejects failed or closed registries. Does not
    read storage or expose keys. Retained records are informational snapshots;
    they do not track later revocation, replacement or live encryption state.
  */
  bonds -> List:
    return mutex_.do:
      check-open_
      snapshot_.bonds

  /** Returns one atomic pair of opaque revision and public metadata records. */
  inventory -> List:
    return mutex_.do:
      check-open_
      [revision_.copy, snapshot_.bonds]

  /** Withdraws this slot's live access before deleting and verifying storage. */
  remove slot/int --if-revision/ByteArray?=null -> none:
    if not 0 <= slot < table_.capacity: throw "INVALID_ARGUMENT"
    if if-revision and if-revision.size != 16: throw "INVALID_ARGUMENT"
    expected := if-revision and if-revision.copy
    change_ slot --if-revision=expected:
      if configuration_: configuration_.remove slot
      table_.remove slot

  /** Closes tracked owners and releases the owned table. */
  close -> none:
    critical-do --no-respect-deadline:
      mutex_.do:
        if closed_: return
        closed_ = true
        snapshot_ = null
        first-error := null
        owners_.do: | owner/TrackedOwner_? |
          if not owner: continue.do
          error := catch: owner.close
          if error and not first-error: first-error = error
        error := catch: table_.close
        configuration-error := catch:
          if configuration_: configuration_.close
        if first-error: throw first-error
        if error: throw error
        if configuration-error: throw configuration-error

  change_ slot/int? --if-revision/ByteArray?=null --require-idle/bool=false [operation]:
    return mutex_.do:
      check-open_
      if require-idle and (owners_.any: it != null): throw "BLE_BOND_OWNERS_ACTIVE"
      // Check freshness under the mutation lock, before closing any live owner.
      if if-revision and if-revision != revision_: throw "BLE_STALE_BOND_INVENTORY"
      next-revision := crypto.random --size=16
      paused_ = true
      succeeded := false
      try:
        result := null
        error := catch:
          if slot != null:
            // Withdraw every matching lifetime even if one abort fails. Defer
            // cancellation until all selected owners have been attempted.
            critical-do --no-respect-deadline:
              first-error := null
              owners_.do: | owner/TrackedOwner_? |
                if not owner or owner.slot != slot: continue.do
                close-error := catch: owner.close
                if close-error and not first-error: first-error = close-error
              if first-error: throw first-error
          result = operation.call
          snapshot_ = table_.snapshot
          revision_ = next-revision
        if error:
          // These admission refusals precede mutation; other failures may be ambiguous.
          if error == "BLE_BOND_TABLE_FULL" or error == "BLE_BOND_ALREADY_EXISTS": succeeded = true
          throw error
        succeeded = true
        return result
      finally:
        if not succeeded:
          failed_ = true
          snapshot_ = null
        paused_ = false

  check-open_ -> none:
    if closed_: throw "BLE_BOND_REGISTRY_CLOSED"
    if failed_: throw "BLE_BOND_REGISTRY_FAILED"

  release_ index/int owner/TrackedOwner_ -> none:
    if owners_[index] == owner: owners_[index] = null

  require-owner_ owner/Owner --allow-paused/bool=false -> TrackedOwner_:
    check-open_
    if paused_ and not allow-paused: throw "BLE_BOND_ADMISSION_PAUSED"
    owners_.do: | tracked/TrackedOwner_? |
      if tracked and tracked == owner: return tracked
    throw "BLE_BOND_OWNER_EXPIRED"

  with-configuration_ owner/TrackedOwner_ [operation]:
    return mutex_.do:
      require-owner_ owner
      result := operation.call
      require-owner_ owner
      result

interface TrackedOwner_ extends Owner:
  slot -> int?
  candidate -> Candidate?

class TrackedResume_ extends Resume implements TrackedOwner_:
  registry_/Registry
  index_/int
  slot/int
  candidate/Candidate

  constructor .registry_ .index_ .slot host/Central link/Link candidate/Candidate
      --local-address/ByteArray --require-authentication/bool:
    this.candidate = candidate
    super host link candidate --local-address=local-address
        --require-authentication=require-authentication

  close -> none:
    try:
      super
    finally:
      registry_.release_ index_ this

class GuardedConfiguration_ implements cccd.Store:
  registry_/Registry
  owner_/TrackedOwner_
  storage_/configuration.Storage
  database-id_/ByteArray
  store_/cccd.Store? := null
  constructor .registry_ .owner_ .storage_ .database-id_:
  load -> ByteArray?:
    return registry_.with-configuration_ owner_:
      store := selected_
      store and store.load
  save state/ByteArray -> none:
    registry_.with-configuration_ owner_:
      store := selected_
      if not store: throw "BLE_BOND_NOT_READY"
      store.save state

  selected_ -> cccd.Store?:
    slot := owner_.slot
    if slot == null: return null
    if not store_:
      store_ = storage_.session slot owner_.candidate --database-id=database-id_
    return store_

/**
Owns fresh pairing and its durably admitted bond for the initial connection.

Created by Registry.bond. Attach this owner to ATT instead of the supplied
  Pairing object. Until run completes, encrypted/authenticated access is withheld,
  including CCCD writes; an early ATT request receives the ordinary insufficient
  security response. This leaves the receive loop free for SMP distribution.
  Successful admission never substitutes a resumption owner on an encrypted link.
  Closing or revoking this owner aborts its connection and invalidates its stores.
*/
class Bonding implements TrackedOwner_:
  registry_/Registry
  index_/int
  pairing_/Pairing
  slot_/int? := null
  candidate_/Candidate? := null
  used_/bool := false
  committed_/bool := false
  closed_/bool := false

  constructor.create_ .registry_ .index_ .pairing_:

  slot -> int?: return slot_
  candidate -> Candidate?: return candidate_
  matches host/Central link/Link -> bool: return pairing_.matches host link
  paired -> bool: return not closed_ and pairing_.paired
  encrypted -> bool: return committed_ and not closed_ and pairing_.encrypted
  authenticated -> bool: return encrypted and pairing_.authenticated
  receive bytes/ByteArray -> none:
    if closed_: throw "BLE_BOND_OWNER_EXPIRED"
    pairing_.receive bytes

  /** Pairs once and durably admits the candidate before granting access. */
  run [confirm] -> none:
    if used_ or closed_: throw "BLE_BOND_PAIRING_INVALID_STATE"
    used_ = true
    succeeded := false
    try:
      pairing_.run confirm --candidate=: | candidate/Candidate |
        registry_.admit_ this candidate
      critical-do:
        registry_.require-owner_ this
        committed_ = true
      succeeded = true
    finally:
      if not succeeded: close

  bind_ slot/int candidate/Candidate -> none:
    slot_ = slot
    candidate_ = candidate

  /** Aborts the link and releases this registry owner, including before pairing. */
  close -> none:
    if closed_: return
    closed_ = true
    committed_ = false
    try:
      pairing_.close
    finally:
      registry_.release_ index_ this
