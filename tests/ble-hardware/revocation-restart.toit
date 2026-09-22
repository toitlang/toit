// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-flash
import ble.experimental.bond-revocation
import ble.experimental.bond-storage show Records Storage
import ble.experimental.smp-identity show Identity

// Public test keys, isolated from production and the radio fixtures. Install as
// a boot container and reset between READY checkpoints. This never resets itself.
main:
  phase := step (bond-flash.FlashRecords "toit.test/ble-revoke-restart-v1")
  if phase < 3:
    print "BOND_REVOCATION_RESTART READY phase=$phase reset-required=true"
  else:
    print "BOND_REVOCATION_RESTART COMPLETE phases=3"

/** Runs one persistent restart stage and closes the supplied backend. */
step records/Records -> int:
  faults := ArmedRecords records
  store := Storage (bond-revocation.RevocableRecords faults) (ByteArray 32 --initial=42)
  try:
    phase := records.read "phase"
    if phase == null:
      // Require a fresh fixture namespace; do not silently overwrite a bond.
      require ((records.read "candidate/01") == null)
      require ((records.read "revoked/candidate/01") == null)
      store.save #[1] (candidate 1)
      faults.fail-remove = "candidate/01"
      require ((catch: store.remove #[1]) == "FIXTURE_INTERRUPTED")
      require ((store.load #[1]) == null)
      require ((records.read "candidate/01") != null)
      checkpoint records #[1]
      return 1
    if phase == #[1]:
      // A separate boot must suppress the surviving old ciphertext.
      require ((store.load #[1]) == null)
      require ((records.read "candidate/01") != null)
      faults.fail-remove = "revoked/candidate/01"
      require ((catch: store.save #[1] (candidate 2)) == "FIXTURE_INTERRUPTED")
      require ((store.load #[1]) == null)
      checkpoint records #[2]
      return 2
    if phase == #[2]:
      // Interrupted replacement stays revoked until a verified replacement
      // deliberately clears the marker, even across another boot.
      require ((store.load #[1]) == null)
      require ((records.read "candidate/01") != null)
      store.save #[1] (candidate 2)
      require ((store.load #[1]).encode == (candidate 2).encode)
      require ((records.read "revoked/candidate/01") == null)
      store.remove #[1]
      require ((store.load #[1]) == null)
      checkpoint records #[3]
      return 3
    require (phase == #[3])
    require ((store.load #[1]) == null)
    return 3
  finally:
    store.close

candidate value/int -> bond.Candidate:
  identity := Identity (ByteArray 16) #[1, 2, 3, 4, 5, 6] 0
  return bond.Candidate (ByteArray 16 --initial=value) identity identity --authenticated

require condition/bool -> none:
  if not condition: throw "BOND_REVOCATION_RESTART_FAILED"

checkpoint records/Records phase/ByteArray -> none:
  records.write "phase" phase.copy
  require ((records.read "phase") == phase)

class ArmedRecords implements Records:
  records_/Records
  fail-remove/string? := null

  constructor .records_:
  namespace -> ByteArray: return records_.namespace
  read name/string -> ByteArray?: return records_.read name
  write name/string bytes/ByteArray -> none: records_.write name bytes
  remove name/string -> none:
    if name == fail-remove: throw "FIXTURE_INTERRUPTED"
    records_.remove name
  close -> none: records_.close
