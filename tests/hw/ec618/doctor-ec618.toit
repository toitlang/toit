// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618
import ec618.slot

/**
Device-side doctor: dumps the identity and layout state a healthy EC618 should be able to report, so rig triage starts from facts instead of silence.
*/

main:
  print "doctor: base-id: $ec618.base-id"
  active := string.from-rune slot.active
  print "doctor: booted slot: $active (trial=$slot.trial)"
  print "doctor: slot size: 0x$(%x slot.SLOT-SIZE) (from the anchor table)"
  console := ec618.console-uart-id
  print "doctor: console/control uart: $(console < 0 ? "off" : "uart$console") (anchor record byte)"
  print "doctor: reset: $(ec618.reset-reason-name ec618.reset-reason), wake: $(ec618.wakeup-cause-name ec618.wakeup-cause)"
  if slot.SLOT-SIZE <= 0:
    print "doctor: FAIL slot size unreadable — anchor table broken?"
    exit 1
  print "doctor: PASS device self-report complete"
