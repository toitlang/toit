// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Run with 'toit run --untrusted'. An uncaught exception from a denied
// primitive ends the program with exit code 1 (the application container is
// critical when it is started at boot) and the system process prints the
// stack trace.
main:
  hostname_

hostname_:
  #primitive.core.hostname
