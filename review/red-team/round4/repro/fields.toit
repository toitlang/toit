// Copyright (C) 2026 Toit contributors.
// Base program with field accesses so the default (trusted) format-2 compile
// emits the unchecked twin opcodes (104..113). Used by the round-4 line-A
// battery: a trusted-compiled image run --untrusted must be rejected, and the
// assembler splices twins into an untrusted method to confirm rejection.
class Box:
  a/int := 0
  b/int := 0
  set-a v/int -> none: a = v
  get-a -> int: return a
  swap -> none:
    t := a; a = b; b = t

box ::= Box

main:
  box.set-a 7
  box.b = 11
  box.swap
  print box.get-a
  print box.a
  print box.b
