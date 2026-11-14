// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system.containers

import .sandbox

// An untrusted container that fails with an uncaught exception only stops
// itself, even though its image is run-critical: sandboxed code can't bring
// down the system by failing. The stack trace is printed by the system
// process. Printing works from a sandbox through the system print service.
main arguments:
  if arguments is Map:
    role := arguments.get ROLE-KEY
    if role == "printer":
      print "printed from a sandbox"
      return
    throw "UNCAUGHT_IN_SANDBOX"
  sandboxed := containers.start containers.current {ROLE-KEY: ROLE-UNTRUSTED} --untrusted
  expect-equals 1 sandboxed.wait
  printer := containers.start containers.current {ROLE-KEY: "printer"} --untrusted
  expect-equals 0 printer.wait
  print "OK"
