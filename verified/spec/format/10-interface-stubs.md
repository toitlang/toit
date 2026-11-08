# 10. Interface-check stubs get a real body

## Problem

Format 1 interface and mixin check stubs are method headers without
bytecodes (`src/compiler/byte_gen.cc`, `IsInterfaceOrMixinStub`); they
exist so that `find_method` succeeds for `is Interface`. A call with their
selector would execute the next method's header as code. The verifier
must exclude their synthetic selectors from every call (report 02,
section 6.4).

## Alternatives

* Exclude their selectors from calls in the verifier.
* A stub kind that calls treat as a lookup failure (a kind compare on
  every virtual call).
* A real body (chosen).

## Decision

The stubs get the terminator body of note 8, `LOAD_NULL; THROW`: calling
one (which no compiler output does) throws null. `find_method` and
`IS_INTERFACE` are unchanged.

## Spec and obligations

Nothing special: the stub is an ordinary method. The verifier obligation
disappears.

## Cost

2 bytes per stub (they now also have a 16-byte header, note 13); no run
time.
