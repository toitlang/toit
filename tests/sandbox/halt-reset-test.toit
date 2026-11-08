// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox
import esp32

// An untrusted program that uses reset (HALT 3) is rejected by the
// verifier when it is launched: starting the container fails and the
// program never runs. The image of this test contains the HALT 3, so
// the untrusted container is refused before the attack can run.
// (A sandboxed process that reaches HALT 3 anyway is terminated with
// containers.EXIT-DEVICE-HALT instead of halting the device.)
main args:
  sandbox-test args --refused="VERIFICATION_FAILED": | arguments/Map |
    esp32.reset
