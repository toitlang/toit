// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// The TERMINATED and SPAWNED notices originate only from the scheduler, so
// even a trusted process (this test's application container) can't send
// them: the system process trusts them, and without a boot process a
// TERMINATED notice on the system route decided the exit state of the VM.
// Both the system route (-1) and a direct route (the own pid) are refused.
// The sandboxed case is forge-terminated-test and forge-spawned-test.
main:
  self := Process.current.id
  [SYSTEM-TERMINATED_, SYSTEM-SPAWNED_].do: | type/int |
    [-1, self].do: | pid/int |
      // A forged notice with a nonzero payload ended the VM with that exit
      // code (42 here) before the fix; 0 last, as it ended it silently.
      [42, 1, null, [1, 2], 0].do: | payload |
        expect-throw "PERMISSION_DENIED": process-send_ pid type payload
