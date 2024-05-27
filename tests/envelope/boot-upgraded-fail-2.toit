// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.firmware

main:
  print "hello from updated"
  print "validation is $(firmware.is-validation-pending ? "" : "not ")pending"
  print "can $(firmware.is-rollback-possible ? "" : "not ")rollback"
  print "not validating and rolling back"
  firmware.rollback
