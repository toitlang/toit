// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import monitor
import .bond-storage show Records

/**
Keeps interrupted deletions logically revoked across backend reopen.

Owns the backend after successful construction. Requires exclusive use of its
  namespace through this wrapper, including after restart. The reserved
  `revoked/` prefix must be unused before adoption. Existing candidate records
  keep their names and authentication context. Do not reopen using bare Records:
  doing so bypasses revocation markers.

Deletion writes and verifies a marker before removing the candidate. The marker
  remains until a replacement has been written and verified. Reads of marked
  records return null even if old ciphertext remains. Markers contain no keys.
  Malformed markers fail closed. This is not protection against storage rollback
  or an attacker removing markers, nor does it revoke already loaded owners.

Crash consistency requires each successful backend mutation to be durable and
  ordered before the next operation. Read-back alone does not prove that property.
  Before the marker write commits, an interrupted deletion can leave the old bond
  available. Errors are ambiguous and require the caller to stop admission.
*/
class RevocableRecords implements Records:
  records_/Records
  mutex_/monitor.Mutex ::= monitor.Mutex
  closed_/bool := false

  constructor .records_:

  namespace -> ByteArray:
    check-open_
    return records_.namespace

  read name/string -> ByteArray?:
    return mutex_.do:
      check-name_ name
      if marked_ name: return null
      records_.read name

  write name/string bytes/ByteArray -> none:
    // Own the input before entering a mutex or awaiting backend IO.
    owned := bytes.copy
    mutex_.do:
      check-name_ name
      marked := marked_ name
      records_.write name owned.copy
      if (records_.read name) != owned: throw "BLE_BOND_WRITE_NOT_VERIFIED"
      if marked:
        records_.remove (marker-name_ name)
        if (records_.read (marker-name_ name)) != null:
          throw "BLE_BOND_REVOCATION_NOT_CLEARED"

  remove name/string -> none:
    mutex_.do:
      check-name_ name
      if not (marked_ name):
        records_.write (marker-name_ name) marker_
        if not (marked_ name): throw "BLE_BOND_REVOCATION_NOT_VERIFIED"
      records_.remove name
      if (records_.read name) != null: throw "BLE_BOND_DELETE_NOT_VERIFIED"

  close -> none:
    critical-do --no-respect-deadline:
      mutex_.do:
        if closed_: return
        closed_ = true
        records_.close

  marked_ name/string -> bool:
    bytes := records_.read (marker-name_ name)
    if bytes == null: return false
    if bytes != marker_: throw "BLE_INVALID_BOND_REVOCATION"
    return true

  check-name_ name/string -> none:
    check-open_
    if name.size == 0 or name.starts-with "revoked/": throw "INVALID_ARGUMENT"

  check-open_ -> none:
    if closed_: throw "BLE_BOND_STORAGE_CLOSED"

marker-name_ name/string -> string: return "revoked/$name"
marker_ -> ByteArray: return #[0x54, 0x42, 0x52, 1]
