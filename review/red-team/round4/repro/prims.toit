// Copyright (C) 2026 Toit contributors.
// Red-team round 4, line A, T2 (2026-11-26): calls of primitives the
// untrusted policy denies or does not have, each in a method whose body is
// the PRIMITIVE with a failure block that returns what the call failed
// with. The verifier accepts them (prim_listed: allowed with the method's
// arity, denied, or absent), and the core must complete them itself:
// a denied primitive fails with PERMISSION_DENIED without running anything,
// a primitive of a module the policy denies as a whole throws
// PRIMITIVE_LOOKUP_FAILED. battery-A.sh runs this untrusted and compares
// the output line by line.
main:
  // Denied, the right arity (spawn/3): no process is spawned. Trusted, the
  // C++ runs and rejects the arguments (INVALID_ARGUMENT).
  print "spawn: $(spawn-3 0 1 2)"
  // Denied, the right arity (write_on_stdout/2): LEAK must not be printed.
  print "stdout: $(stdout-2 "LEAK\n" false)"
  // Denied, a wrong arity (spawn called from a 1-parameter method).
  print "spawn-arity-1: $(spawn-1 0)"
  // Denied, a wrong arity (write_on_stdout from a 0-parameter method).
  print "stdout-arity-0: $stdout-0"
  // Absent: tcp is a module the untrusted policy denies as a whole.
  e := catch: tcp-close-2 0 0
  print "tcp: $e"
  // Absent, a wrong arity.
  e = catch: tcp-close-5 0 0 0 0 0
  print "tcp-arity-5: $e"
  print "done"

spawn-3 a b c:
  #primitive.core.spawn: | e | return "failed $e"

stdout-2 message flush:
  #primitive.core.write_on_stdout: | e | return "failed $e"

spawn-1 a:
  return "placeholder: battery-A.sh assembles PRIMITIVE core.spawn here"

stdout-0:
  return "placeholder: battery-A.sh assembles PRIMITIVE core.write_on_stdout here"

tcp-close-2 a b:
  #primitive.tcp.close: | e | return "failed $e"

tcp-close-5 a b c d e:
  return "placeholder: battery-A.sh assembles PRIMITIVE tcp.close here"
