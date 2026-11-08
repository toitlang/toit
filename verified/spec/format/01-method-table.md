# 1. Method ids are indices into a method table

## Problem

In format 1 a method id is the byte offset of the method's 4-byte header
in the bytecodes. Whether a smi is a method id cannot be decided from the
bytecodes: the spec needed the method table from the debug source map
(`method_start`), and the VM trusts every id it reads (DESIGN.md item 1).
Ids travel as plain smis through the heap (`Lambda.method_`,
`LazyInitializer_.id-or-tasks_`), so any smi a program computes can become
a jump target. The header does not say where the method ends, so neither
the VM nor a verifier knows the extent of a method without the source map.

## Alternatives

* Keep offsets and give the verifier a sorted method-entry table to check
  heap-derived ids against (report 02, P2: a binary search per lambda
  call).
* Indices into a method table (chosen).
* Tag method ids as a separate value kind (an unforgeable word type):
  needs a new tag in the object model and the GC; the heap fields that
  hold ids are written by Toit code, so the tag would also need new
  primitives to create lambdas.

## Decision

Method `i` is the `i`-th method in the bytecodes. The bytecodes start with
the tag `TBC2`, then the methods back to back, each a header and its
body. The header holds arity, kind, body length, selector, receiver range
and aux; its encoding (two bytes plus LEB128 numbers, 5.2 bytes on
average) is in note 15. The first encoding was a fixed 16 bytes:

    arity u8 | kind u8 | max height u16 | selector u16 | aux u16
    | receiver range start u16 | end u16 | body length u32

`aux` is the captured count of a lambda and the field index of a field
accessor (format 1 decoded the accessor's bytecodes at run time, DESIGN.md
item 6). The trusted loader decodes the table (`interp/loader.rs`
`method_table_v2`; in the VM it would be built at load time, 16 bytes per
method in RAM or read from flash). Dispatch-table entries, `LOAD_METHOD`
operands, lambda and initializer ids and entry points are method ids.
`INVOKE_STATIC` keeps the dispatch-table indirection (the compiler emits
calls before it has assembled their targets, and the table doubles as the
static-method table).

## Spec and obligations

`valid_method(p, m)` is `0 <= m < methods.len()`; the method-start bitmap
and `method_entry(id) = id + 4` disappear. Every instruction fetch is
checked against the current frame's method (`instruction_ok`: `entry <=
bci` and `bci + length <= end`), which makes "execution stays inside the
method body" part of the semantics. Obligations moved to the verifier:
`LOAD_METHOD` operands are method indices, dispatch entries are methods of
kind method or accessor. Heap-derived ids become run-time checks (note 12),
which are now a bounds check and a kind compare instead of a search.

## Cost

Run time: one indirection more per call in a VM that keeps code in flash
(`methods[id].entry`) unless the table is kept in RAM (12-16 bytes per
method; 750 methods for hello world, ~12 KB) or calls are resolved to
addresses at load time, which the verified loader can do since it knows
the table. Interpretation itself is unchanged. Code size: see notes 13 and 15 (the
16-byte header cost 3.4 MB vs 0.9 MB of headers over the test suite; the
variable-length header of note 15 costs 1.1 MB, and format 2 as a whole is
smaller than format 1).
