# 7. Checked field access, unchecked only for `this`

## Problem

Format 1 field instructions do not check the receiver: `Instance::cast`
and the field index are trusted. Report 02 (section 5) measured that the
verifier can derive the receiver class for only 27-34 % of the sites
from `this` and header ranges, the rest needing declared ranges for
constructors (P3) and kept or inserted `AS_CLASS` witnesses (P4), i.e. a
compiler-side mirror of the verifier's type lattice.

## Alternatives

* Proof-carrying receiver ranges and kept `AS_CLASS` checks (report 02's
  recommendation, P3+P4).
* Check every field access (report 02 option b): 3-8 cycles per access.
* Checked by default, unchecked for `this` (chosen).

## Decision

LOAD_FIELD, LOAD_FIELD_LOCAL, POP_LOAD_FIELD_LOCAL and the STORE_FIELD
forms check that the receiver is an instance with the field (and, for
stores, that it is not a read-only program-heap object) and raise
`INVALID_PROGRAM` otherwise. LOAD_FIELD_THIS `f` and STORE_FIELD_THIS `f`
address parameter 0 of the frame directly and are not checked. They are
only allowed in methods whose header declares a receiver class-id range
`[start, end)` (the compiler declares the holder's range for every
instance method and constructor of a class or monitor). The range is
established by:

* virtual dispatch: a method found for class `c` declares a range
  containing `c` (a table check: `tables_ok`);
* static calls (INVOKE_STATIC, INVOKE_STATIC_TAIL, entry-point calls) to
  a method with a range: the machine checks the receiver's class id
  against the range (two compares) and raises `AS_CHECK_FAILED`;
* the verifier: parameter 0 is never overwritten in such a method, and
  every class of the range has the field.

Program-heap writes are still checked at run time for STORE_FIELD_THIS.
INVOKE_VIRTUAL_GET/SET use the accessor's field index from the header and
fall back to the call if the field check fails.

## Spec and obligations

The field family stays the same size; `this_ok` adds 8 lines, the
receiver check 15. The verifier no longer needs a type lattice or
witnesses: its obligations are a table check and "slot 0 is not written".
Proven: all nine field instructions.

## Cost

Measured on the test suite: 93 % of executed field loads (2.40 M of 2.59
M) and 89 % of field stores (0.51 M of 0.57 M) are `this` accesses and
run unchecked; 0.19 M loads and 0.06 M stores pay the check (3-8
cycles). Statically, 47 % of the static call sites of hello world
(337/722) target a method with a receiver range and pay two compares per
call. LOAD_FIELD_THIS also saves the LOAD_LOCAL that format 1 needs for
`this` (format 1 fuses most of them into LOAD_FIELD_LOCAL). Estimated
under 1 % on field-heavy code.
