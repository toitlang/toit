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

## The method header (done, note 15)

The 16-byte header of note 1 was generous: over the test suite headers
grew from 0.88 MB to 3.37 MB and the bytecodes as a whole by 22.7 %. The
8-byte header proposed here (arity u8, kind u8, selector u16, body length
u16, one u16 for the receiver-range index, captured count or field index;
max height per program) would have left format 2 at +3.0 % on the
measured programs. Note 15 replaces it with a variable-length header (two
bytes plus LEB128 fields, 5.2 bytes on average): format 2 is now 4.2 %
smaller than format 1. Only the loader changed; the abstract program did
not.
