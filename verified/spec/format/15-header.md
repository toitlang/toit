# 15. A variable-length method header

## Problem

The 16-byte header of note 1 grew the bytecodes of the test suite by
21-23 % although the method bodies shrink by 11 % (note 13). Note 13
proposed a fixed 8-byte header. Measured on the programs below it would
still leave format 2 at +3.0 % over format 1 (620 952 body bytes + 8 x
19 349 methods vs 753 116), above the +2 % target, and it had no room
for both the receiver range and the field index of a field accessor.

What the headers hold (19 349 methods of the three system snapshots and
ten test programs, format 2 before this change):

* kind: 72 % methods, 22 % blocks, 5 % field accessors, 1 % lambdas;
* arity: 99.98 % below 15, all below 256;
* body length: 96 % below 128 bytes, 99.2 % below 256, none near 64 KB;
* selector: 39 % of the methods (static methods, blocks and lambdas have
  none), 84 % of them at least 128;
* receiver range: 61 % of the methods, 79 % of the ranges a single class,
  the start below 128 in 75 %;
* aux (captured count, field index): only for lambdas and accessors,
  always below 128;
* max height: not used by the spec, the verifier or the loader.

## Alternatives

* The fixed 8-byte header of note 13 (arity, kind, selector, length u16,
  one u16 shared by the receiver-range index, the captured count and the
  field index): +3.0 %, bodies limited to 64 KB, and the accessor loses its
  receiver range, so its body could not use `LOAD_FIELD_THIS`.
* Variable length, receiver range as an index into the class-check table:
  4.6 bytes per method, but the compiler must append the holder ranges to
  the table (461 new entries over the 13 programs, 1.8 KB) and the header
  can no longer be decoded without that table. 1.3 % smaller than the
  chosen encoding.
* Variable length with arity packed into the flags byte (escape for arity
  >= 15): one byte less per method (2.6 %), at the price of an escape path
  that 3 methods out of 19 349 take.
* Variable length, self-contained (chosen).

## Decision

A header is two bytes followed by unsigned LEB128 numbers (7 bits per
byte, low bits first, top bit set when another byte follows):

    u8   arity
    u8   flags: bits 0-1 kind, bit 2 HAS_SELECTOR, bit 3 HAS_RECEIVER,
         bits 4-7 zero
    leb  body length
    leb  selector offset                     if HAS_SELECTOR
    leb  receiver start, leb receiver size   if HAS_RECEIVER
    leb  captured count / field index        if kind is lambda / accessor

The loader (`interp/loader.rs`, `method_table_v2`) rejects unknown flag
bits, numbers longer than 4 bytes or not in their shortest form (each
header has exactly one encoding), a selector of 0xffff, an empty receiver
range or one past 0xffff, and bodies past the end of the bytecodes. The
max height moves out of the header: the program's
`global_max_stack_height` (already in every snapshot) bounds every method,
and the loader puts it into `MethodInfo.max_height`. The verifier computes
exact heights anyway (it checks the stack discipline), so a VM that wants
per-method bounds for its stack-overflow check can take them from the
verifier.

The abstract program is unchanged: `MethodInfo` (in `src/types.rs`) and
`Program2` (in `src/v2/types.rs`) still hold arity, kind, selector, aux,
receiver range, entry and end; only the byte-level decoding of the
trusted loader changed. Nothing in `src/v2` changed; `verus` still reports
0 errors.

## Cost

Decoding: a header is no longer at a fixed size, so method `i` cannot be
found without the headers before it. It could not before either (the body
lengths vary), so the loader already decoded the whole table at load time
(note 1); the VM keeps either the decoded table (12-16 bytes per method)
or the entry offsets (4 bytes per method) and decodes a header on use.
Arity and flags stay at fixed offsets.

Size, three system snapshots (`-O2`, as the build embeds them) and ten
test programs, measured with `verified/tools/code_size.toit`. Bytecodes
include the headers and the 4-byte tag; "snapshot" is the program snapshot
(the `snapshot` member of the bundle, without the source map). Format 1 and
"after" were measured on the same tree; "before" (16-byte headers) on the
tree before this change, whose `tools/snapshot.toit` had two methods
fewer (329 bytes of the `toit` bodies).

| program | f1 bytecodes | f2 before | f2 after | after vs f1 | f1 snapshot | f2 before | f2 after | after vs f1 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| toit | 314971 | 375867 | 302266 | -4.0 % | 628883 | 689557 | 616069 | -2.0 % |
| toit_run | 58951 | 73121 | 55970 | -5.1 % | 75480 | 89617 | 72466 | -4.0 % |
| run_image | 50985 | 64013 | 48224 | -5.4 % | 62047 | 75048 | 59259 | -4.5 % |
| map-test | 31940 | 40774 | 30243 | -5.3 % | 38242 | 47064 | 36533 | -4.5 % |
| deque-test | 33523 | 41843 | 32080 | -4.3 % | 41009 | 49317 | 39554 | -3.5 % |
| byte-array-test | 30172 | 38221 | 28758 | -4.7 % | 37106 | 45142 | 35679 | -3.8 % |
| encoding-test | 30232 | 37855 | 28835 | -4.6 % | 37809 | 45412 | 36392 | -3.7 % |
| ble-advertisement-test | 39208 | 48051 | 37513 | -4.3 % | 48107 | 56932 | 46394 | -3.6 % |
| is-as-many-test | 39600 | 53980 | 40026 | +1.1 % | 52951 | 67316 | 53362 | +0.8 % |
| format-test | 30089 | 37436 | 28654 | -4.8 % | 38275 | 45608 | 36826 | -3.8 % |
| string-slice-test | 25956 | 33046 | 24696 | -4.9 % | 33093 | 40170 | 31820 | -3.8 % |
| coap-tcp-client-test | 38789 | 49402 | 37022 | -4.6 % | 47423 | 58015 | 45635 | -3.8 % |
| constructor-super-test | 28700 | 36541 | 27402 | -4.5 % | 35111 | 42939 | 33800 | -3.7 % |
| **total** | 753116 | 930150 | 721689 | **-4.2 %** | 1175536 | 1352137 | 1143789 | **-2.7 %** |

Before the change format 2 was +23.5 % in bytecodes and +15.0 % in
program snapshots. Headers: 77 396 bytes in format 1 (4 per method),
309 588 before, 100 737 after (5.2 bytes per method on average). The one
program that stays above format 1, `is-as-many-test`, consists mostly of
small methods of many classes, each with a selector and a receiver range;
it is +1.1 %.

Over the 272 tests of the suite that run in both formats
(`run_suite.toit --format both`): bytecodes 8.04 MB in format 1, 9.76 MB
before (+21.4 %), 7.46 MB after (-7.3 %); headers 0.89 MB, 3.43 MB, 1.12
MB.
