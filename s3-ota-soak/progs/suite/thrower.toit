// Copyright (C) 2026 Toit contributors.

// A container that dies with an uncaught exception: the system prints the
// encoded stack trace (a system message) on the serial port.

class Thing:
  value/int
  constructor .value:

  compute depth/int -> int:
    if depth == 0: throw "THROWER-FAILURE $value"
    return (compute depth - 1) + 1

helper x/int -> int:
  return (Thing x).compute 3

main:
  print "THROWER start"
  helper 42
