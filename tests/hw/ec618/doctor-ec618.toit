// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Device-side doctor: dumps the identity and layout state a healthy EC618
should be able to report, so rig triage starts from facts instead of
silence. Run via the tester like any test:

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-tty> tests/hw/ec618/doctor-ec618.toit
*/

import ec618
import ec618.slot

main:
  print "doctor: base-id: $ec618.base-id"
  active := string.from-rune slot.active
  print "doctor: booted slot: $active (trial=$slot.trial)"
  print "doctor: slot size: 0x$(%x slot.SLOT-SIZE) (from the anchor table)"
  console := ec618.print-uart-id
  print "doctor: console/control uart: $(console < 0 ? "off" : "uart$console") (anchor record byte)"
  print "doctor: reset: $(ec618.reset-reason-name ec618.reset-reason), wake: $(ec618.wakeup-cause-name ec618.wakeup-cause)"
  if slot.SLOT-SIZE <= 0:
    print "doctor: FAIL slot size unreadable — anchor table broken?"
    exit 1
  print "doctor: PASS device self-report complete"
