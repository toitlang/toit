// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Pairs on the first boot and resumes on later boots, using the fixture's
// isolated namespace, so one image serves both phases.
import ble.experimental.bond-flash
import ble.experimental.bond-storage
import ...central-fresh-bond as fixture

main:
  store := bond-storage.Storage (bond-flash.FlashRecords "toit.test/central-fresh-001") (ByteArray 32: it)
  exists := false
  try:
    exists = (store.load #[1]) != null
  finally:
    store.close
  print "RESUME_FEATURES boot mode=$(exists ? "resume" : "pair")"
  fixture.run --resume=exists
