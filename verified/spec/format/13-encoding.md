# 13. Encoding details

## Opcode numbers

Format 2 keeps the numbers of the 94 format-1 opcodes it shares, so that
the compiler's peephole optimizer (which inspects emitted opcodes) works
for both formats, and reuses three freed numbers: STORE_FIELD_THIS = 94
(was NON_LOCAL_RETURN_WIDE), TRY = 97 (LINK), LOAD_FIELD_THIS = 98
(UNLINK). The table is dense, 0..100; 101..104 (the intrinsics) are
invalid. Alternative: a fresh numbering grouped by instruction class; it
would cost a translation table in the emitter for no gain in the spec.

## Operands removed

RETURN, RETURN_NULL, NON_LOCAL_RETURN, THROW, INVOKE_LAMBDA_TAIL and
INVOKE_INITIALIZER_TAIL lose their operands (the frame stack knows the
height and arity, note 2); INVOKE_STATIC_TAIL keeps only the dispatch
index (note 6); BRANCH_BACK* keep only the distance (note 9);
NON_LOCAL_RETURN_WIDE is gone. Together with TRY these shrink method
bodies by 10.3 % on the test suite (6.96 MB -> 6.24 MB).

## No silent wrapping

`LOAD_SMI_U32` and `LOAD_METHOD` operands must be smis (format 1 wrapped
`Smi::from` on 32-bit machines, DESIGN.md item 11): stuck otherwise, the
verifier checks the operand (< 2^30). Dynamic global indices are checked
as whole smis (no `int` truncation). The unwinding reasons are no longer
smis (note 4). `INVOKE_DIV` takes the slow path for `MIN_SMI / -1`, as
the VM does since c5d7adec.

## The method header (to shrink)

The 16-byte header of note 1 is generous: over the test suite headers
grow from 0.88 MB to 3.37 MB and the bytecodes as a whole by 22.7 %. An
8-byte header suffices: arity u8, kind u8, selector u16, body length u16
(the compiler splits nothing today; no method body in the suite comes
near 64 KB), and one u16 that is the receiver range as an index into the
class-check table (which already holds start/end pairs; 0 for none) for
methods, the captured count for lambdas, and for field accessors the
field index (accessors have no other use for it: their receiver range
can be the class-check entry of their holder, added to the table by the
compiler like the ranges of statically resolved methods). The max height
moves to a per-program maximum. That brings the total to about +1 % over
format 1 while keeping the body savings. The decision is postponed to Phase 3 so that
the header stays easy to read while the verifier is written; it changes
only the loader.
