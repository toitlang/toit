# 14. Rejected or deferred candidates

## Block-parameter mask in the method header (P7) — deferred

Report 02 proposes one byte per method marking block parameters, to turn
the verifier's fixpoint into one pass. Format 2 keeps the mask in the
verifier's certificate (`Cert.block_params`) instead of the program: the
compiler knows it (`Parameter::is_block`) and can emit it as a side table
when the device verifier needs it, without a format change; the
verifier's table check makes all methods of a selector agree. Revisit in
Phase 3 if the side table is awkward.

## Unique activation ids in block references — rejected

A frame id per activation would let the VM detect a stale block
reference at run time. The verifier already excludes stale references
(note 3), the check would cost a compare per block use and a word per
frame, and a stale reference that passes `ref_ok` is memory safe.

## Run-time bound on the dispatch-table index (P10) — rejected

`find_method` indexes `dispatch[class_id + selector]`. Format 2 keeps
this unchecked and makes "every selector fits for every class" a table
check of the verifier (`tables_ok`), as format 1's verifier prototype
does; the compiler already sizes the table that way. A run-time compare
per virtual call buys nothing once the table is verified.

## Shipped stack maps — deferred

Declared stack maps per basic block would make verification a linear
check (report 02, section 4.1). The spec's verifier is stated as checking
a certificate of stack maps, so either a shipped or a computed
certificate fits; Phase 3 decides whether the device computes it.

## Keeping the frame words with a defensive unwinder (P5) — superseded

Note 2's frame stack removes the frame words that P5 protects.

## AS_CLASS witnesses for field receivers (P3/P4) — superseded

Note 7's checked-by-default field access with the `this` variant needs
neither declared receiver ranges for constructors' arbitrary receivers
nor kept typechecks; only the `this` variant needs a range, which the
compiler always knows.

## Arity in PRIMITIVE — not needed

Format 1's primitive arity comes from the VM's table and success returns
from the enclosing method (DESIGN.md item 9). In format 2 the arguments
are the frame's parameters and success is an ordinary return from the
frame, so the arity is the method's; nothing to add to the encoding.
