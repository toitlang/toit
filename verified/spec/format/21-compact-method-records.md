<!-- Copyright (C) 2026 Toit contributors. -->
# 21. Four-byte method records; the header ends at the entry

## Problem

Notes 1 and 15 made a method id an index into a method table that the
loader decodes from LEB128 method headers. Since device/format2 (M3) the
compiler appends that table as the program's last literal, 16 bytes per
method (`V2Method`: entry u32, length, selector, aux, receiver start and
end u16, arity, kind), and the VM uses it in place from flash after
re-decoding every header and comparing. On the classic ESP32 the table
costs +28.8 KB in the system image and +29.4 KB in Jaguar's (1,743 and
1,837 methods) and is the largest part of the 72 KB by which the format-2
firmware with Jaguar misses the OTA partition. Format 1 had no table.

## What the hot paths read

From the record (callgrind of the verified loop, richards: 3.2 M virtual
calls, 2.5 M getter calls, 1.1 M static calls per 1,073 M instructions):

* every call: entry and arity (the frame base is `sp + arity`); returns
  read neither (the frame record holds the base);
* virtual lookups (INVOKE_VIRTUAL, INVOKE_VIRTUAL_GET/SET, interface
  checks): the selector of the dispatch target;
* static calls (INVOKE_STATIC, INVOKE_STATIC_TAIL): the receiver range of
  the target (61 % of the methods have one);
* getters and setters: the kind (accessor?) and the field index (aux);
* lambdas and initializers (rarer): kind, captured count, arity;
* nobody on the verified paths: the body end (the verifier proves
  every fetch and branch inside the method; the checked loop and the
  verifier use it).

## Alternatives (sizes: system image and Jaguar, 3,580 methods; speed:
host callgrind Ir against the base, see "Cost")

| Layout | Record | Header (avg) | Table + headers | Saved | Hot-path cost |
|---|---:|---:|---:|---:|---|
| base (notes 1, 15): 16-B record, LEB header | 16 B | 5.0 B | 75.3 KB | 0 | base |
| E1: 4-B record (entry, arity), header read backwards from the entry, fields present per flag bit, fixed-width u16 | 4 B | 4.3 B | 29.7 KB | 45.6 KB | +6 to +11 % (offsets depend on the flags: setcc chains, a flags load per lookup) |
| E2: E1 with a one-class receiver range as one u16 | 4 B | 3.3 B | 26.1 KB | 49.2 KB | as E1 |
| K2 (chosen): 4-B record; kind byte; every field at a fixed distance from the entry, 0xffff for none | 4 B | 4.6 B | 30.7 KB | 44.6 KB | richards +0.7 %, deltablue +0.5 %, pystone +0.2 %, json and RPC 0 |
| F: K2 without the kind byte, kind in the record (entry 22 bits) | 4 B | 4.4 B | 30.2 KB | 45.1 KB | block and lambda kind tests +2 instructions; 4 MB bytecode limit |
| K3: K2 with the arity in the header, record = entry u32 | 4 B | 5.6 B | 34.3 KB | 41.1 KB | a dependent load per call |
| 8-B record (entry, arity, kind, selector) + K2-like header | 8 B | 3.6 B | 41.5 KB | 33.8 KB | as base |
| 2-B record scaled by a 2-byte method alignment (wide variant by flag) | 2 B | 5.6 B + 0.5 pad | 28.0 KB | 47.3 KB | a dependent arity load per call; two table widths in the core, the verifier and the certificate path |
| no table: call operands, dispatch entries, lambda and block ids as bytecode offsets (format 1 style) | 0 | 5.0 B | 18.0 KB + bitmap | 50 KB, but | see below |
| sparse table (one record per N methods, scan) | 4/N B | 5.0 B | | | a header scan per call |

Why no table at all does not pay: method ids reach the machine from the
heap (lambdas, lazy initializers) and from block slots, and are checked
by an index bound and a kind compare (note 12). With offsets that check is
"is this an entry?": a bitmap of the bytecodes (1 bit per byte: 7.4 KB for
the system image, as large as the 4-byte table) or a binary search per
lambda call (note 1, report 02 P2). Dispatch entries are 4 bytes either
way; frames would hold offsets and returns would need the arity from the
header. The id indirection also lets the compiler emit calls before their
targets are placed (note 1) and keeps every id a dense index the verifier
bounds once. And every method-identity statement of the spec, the
verifier's soundness proof and the certificate format (which names
methods by index) would change: weeks, not days.

The 2-byte record saves 2.7 KB more than K2 but needs a second table width
(programs above 128 KB of bytecodes), an aligned layout and a header load
for the arity on every call. The sparse table trades every call for a
scan.

## Decision (K2)

A record is a u32, the entry (absolute bci of the first instruction) in
the high 24 bits and the arity in the low 8: `entry = r >> 8`, `arity =
r & 0xff` (one shift, one byte extract on every call; bytecodes are below
16 MB). The table literal is the program's last literal:

    u32 "TMT2"   u32 count   u32 bytecodes length   u32 0   count records

The header ends at the entry. Its last byte, the kind byte, is the kind (0
method, 1 field accessor, 2 lambda, 3 block) or 4 (a method whose receiver
range is one class, or none). Every other field is a little-endian u16 at
a fixed distance before the entry:

| | e-9 | e-7 | e-5 | e-3 | e-1 |
|---|---|---|---|---|---|
| method (kind byte 0) | | recv end | recv start | selector | 0 |
| method, one class or none (4) | | | recv start | selector | 4 |
| accessor (1) | field index | recv end | recv start | selector | 1 |
| lambda (2) | | | | captured count | 2 |
| block (3) | | | | | 3 |

The selector and the receiver start are 0xffff for none; a one-class
range [s, s+1) stores s only. A body ends at the next method's header (the
last at the end of the bytecodes): the header has no length. The table
cannot be rebuilt from the bytecodes, so it is mandatory (`compute()`
refuses a program without it; `-Xv2_table_literal` is gone).

The entries of methods, accessors and lambdas are odd (amendment, branch
core/call-speed-size; blocks have no u16 field and are exempt). Every
header has an odd size, so it starts at an even offset; where the previous
body ends at an odd offset the compiler appends one pad byte to it
(RETURN_NULL: never executed, a terminator for linear decoders). With
2-byte aligned bytecodes (program heap and off-heap blocks are word
aligned) every u16 field is then 2-byte aligned. `rec_ok` (so `table_ok`,
`x_table_ok`, `V2MethodTable::compute`, the dump loader) requires the odd
entries, `compute()` and `toit_v2_run` the aligned bytecodes
(`prog_rel`: `Table::even`).

The decoding is one spec function, `vprog::vdecode(code, recs, i)`, total
(a byte outside the bytecodes reads as 0), shared by the verifier
(`MTable`, whose view is the decoded table, so the verifier's statements
about `p.methods@` did not change) and the core (`Program::minfo`).
`Program2` and `MethodInfo` are unchanged: the abstract machine, the
verifier and its soundness theorem do not see the encoding.

The loader's contract `prog_rel` gains `table_ok(code, recs)`: every
header lies inside the bytecodes before its entry and its kind byte is
canonical (at most 4). The core reads headers without bounds checks under
it; `V2MethodTable::compute` checks it for every program (and the
canonical form: the methods back to back from the tag, nonempty bodies,
SINGLE only for methods, a long range of at least two classes, no empty
accessor range), and the launch verifier checks it again in verified code
(`x_table_ok`) for untrusted programs.

The core's hot paths read only what they need, at constant offsets:
lookups read the selector at e-3 without a kind test, static calls the
receiver start at e-5 (and the end at e-7, or compare one class), because
a dispatch target of an accepted program is a method or an accessor
(`verifier::dispatch_entry_ok`, `calls::lemma_dispatch_kind`); getters and
lambdas test the kind with one compare of the canonical kind byte
(`Program::is_kind`).

## Spec and obligations

New: `vdecode`, `table_ok`, `MTable` with its verified `at`/`len`/`get`
and `x_table_ok` (verified/spec/src/v2/vprog.rs); the core's readers
`Program::{method, entry_of, arity_of, is_kind, dispatch_selector,
dispatch_recv_start, dispatch_recv_contains}` (exec.rs) and
`calls::lemma_dispatch_kind`. `prog_rel` relates `ap.methods[i]` to
`method_info(p.minfo(i))` and states `table_ok`; `lookup` and
`check_type` additionally require `accepts`. No admit, no new trusted
item; the trusted statement that grew is the loader's `prog_rel`
(`theorem::loaded`), by `table_ok`.

## Cost

Size (classic ESP32, see verified/core/PROGRESS.md, "Compact method
records"): the table 16 -> 4 bytes per method, headers 5.0 -> 4.6 bytes
on average (no length, no LEB; fixed u16 fields; blocks 1 byte).

Speed (callgrind Ir, trusted format 2, against the starting point):
richards +0.7 %, deltablue +0.5 %, pystone +0.2 %, json 0.0 %, RPC -0.1
%; static and virtual call micro-benchmarks equal. A first layout with
flag-dependent offsets (E1) cost 6 to 11 %, mostly setcc chains computing
offsets and a flags load and test on every lookup.

Verification: the launch verifier decodes a method on every access
(`MTable::at`) instead of reading a 16-byte record; no table in RAM.

## Xtensa (amendment, branch core/call-speed-size)

The host numbers above hid a regression on the classic ESP32 (QEMU
`-icount`, f2/f1 instructions; the benchmark-only suite): the first K2
version cost richards +7.5 %, deltablue +7 %, pystone +6 %, json +3 %
against the 16-byte records. Xtensa has no unaligned 16-bit load and
only unsigned load offsets, so each u16 field before the entry was `addi,
l8ui, addi, l8ui, slli, or` (RISC-V `lbu, lbu, slli, or`), and the
selector check of a virtual call grew from 5 to 10 instructions.

Layouts considered (per hot field read, Xtensa):

| Layout | Read | Cost | Kept |
|---|---|---|---|
| K2 as first merged | 2 byte loads, shift, or, 2 addi | 6 | no |
| fields after the entry (header after a jump) | | a dispatch per call | no |
| fields at positive offsets from a header pointer | 1 load | the entry needs the header size: a kind load per call | no |
| byte fields with an escape | 1 load, compare | selectors and receiver ids exceed a byte: an escape test per read | no |
| hot field in the record's spare bits | | no spare bits (24-bit entry, 8-bit arity; the selector is 16 bits) | no |
| odd entries, aligned u16 fields (chosen) | `l16ui` with the distance folded into its offset | 1 | yes |

The chosen layout reads a field with one aligned 16-bit load (trusted
leaf `Table::u16_at_even`: two bytes the table's permissions cover, read
as `u16::from_le` of an aligned load) at `pre + entry + (PRE - d)`, where
the table's `pre` pointer lies `PRE` = 15 elements before its start (odd,
so that the offset is even and encodable). The padding costs 784 bytes in
Jaguar's bytecodes and 710 in the system image's (one byte for 43 % of the
non-block methods; 1.5 KB of the 44.6 KB saved).

The rest of the regression was code generation of the call paths:
virtual calls take the callee's arity from the call's operand (the spec is
stuck otherwise) instead of decoding it from the record, class ids are
words (64-bit compares on a 32-bit target were 6 to 12 instructions per
receiver-range or class check) and the header's class id is one logical
shift. Result (QEMU, benchmark-only suite, f2/f1; pre-compact 16-byte
records in parentheses): richards 0.696 (0.708), deltablue 0.947 (0.994),
pystone 0.867 (0.857), json 1.031 (1.076). Host (callgrind, trusted):
richards 1,066 M, deltablue 754 M, pystone 810 M, json 1,314 M, RPC 417 M
(EXPERIMENT-trusted.md: 1,078 / 761 / 810 / 1,332 / 444). RISC-V (C6):
the selector check is `lw, add, lhu` instead of `lbu, lbu, slli, or`; the
run loop shrank by 600 bytes.
