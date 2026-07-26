// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618

/**
Sets the freshly staged OTA's console (rig utility, not a test).

The target UART id comes in as the test argument.

The device must already carry a NEW trial staged by an OTA commit. The
  change takes effect when that trial boots; validation promotes it and
  rollback restores the known-good image's console. Calling this utility
  without a staged trial is expected to fail.
*/

main args:
  target := int.parse args[0]
  before := ec618.console-uart-id
  ec618.set-console-uart target
  print "console-set: staged console $before -> $target (takes effect with the trial)"
