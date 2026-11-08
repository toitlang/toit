// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox
import system.containers

// A process that exceeds its CPU budget is killed by the VM.
main args:
  sandbox-test args --exit=containers.EXIT-CPU-BUDGET --quotas={"cpu-ms": 300}: | arguments/Map |
    while true: null
