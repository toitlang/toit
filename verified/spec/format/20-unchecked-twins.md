# 20. Unchecked twins of the field accesses (trusted programs)

Status: experiment (branch experiment/trusted-fast), not decided.

## Why

The field accesses on a receiver other than `this` (LOAD_FIELD,
LOAD_FIELD_LOCAL, STORE_FIELD and their variants), the stores into `this`
(STORE_FIELD_THIS: the program-heap check) and the field-accessor fast
paths of INVOKE_VIRTUAL_GET/SET check at run time that the receiver has
the field (note 5: a failure raises INVALID_PROGRAM). The verifier cannot
prove these accesses in general, so untrusted programs need the checks.
First-party (trusted) programs come from a compiler we trust, and the C++
interpreter never checked them.

A program-wide mode flag (`Program2::unchecked`, tested in the handlers)
made trusted programs faster but cost untrusted code about 2 percent on
richards: every checked field access tested the flag. The twins move the
choice from run time into the opcode: the checked handlers are exactly
the ones untrusted programs had before the mode existed.

## Opcodes

| Opcode | Name | Twin of | Length |
|---|---|---|---|
| 104 | LOAD_FIELD_U | LOAD_FIELD (7) | 2 |
| 105 | LOAD_FIELD_WIDE_U | LOAD_FIELD_WIDE (8) | 3 |
| 106 | LOAD_FIELD_LOCAL_U | LOAD_FIELD_LOCAL (9) | 2 |
| 107 | POP_LOAD_FIELD_LOCAL_U | POP_LOAD_FIELD_LOCAL (10) | 2 |
| 108 | STORE_FIELD_U | STORE_FIELD (11) | 2 |
| 109 | STORE_FIELD_WIDE_U | STORE_FIELD_WIDE (12) | 3 |
| 110 | STORE_FIELD_POP_U | STORE_FIELD_POP (13) | 2 |
| 111 | INVOKE_VIRTUAL_GET_U | INVOKE_VIRTUAL_GET (60) | 3 |
| 112 | INVOKE_VIRTUAL_SET_U | INVOKE_VIRTUAL_SET (61) | 3 |
| 113 | STORE_FIELD_THIS_U | STORE_FIELD_THIS (94) | 2 |

`OPCODE_COUNT2` is 114. A twin has the operands, the stack effect and
the typing of its base (`bytecodes::base_op`).

## Semantics (`src/v2/spec.rs`)

`step` dispatches on `base_op` of the opcode byte, so a twin runs its
base's step function. The only difference is `unchecked_fail`: where the
base raises INVALID_PROGRAM (the run-time check failed), a twin is stuck
(`Stuck::FieldRange`, used for nothing else in format 2); the same for the
accessor fast paths (`twin_at`). The machine does not check: the access
is assumed to succeed.

## Verifier (`src/v2/verifier.rs`, `src/v2/check.rs`, `src/v2/infer.rs`)

`op_of` is `base_op` of the byte, so a twin is typed as its base. In
addition `instr_ok` requires the byte below `OPCODE_COUNT2` and a twin
only in a program in the unchecked mode (`Program2::unchecked`, which
`accepts` allows only with `trusted`). The VM's launch verifier sets the
mode exactly for the trusted rules (verified/vmverify `verify`), so an
untrusted program with a twin is rejected.

## Soundness

The theorem (`theorem_soundness`, `lemma_run_wf`) is stated for programs
without the mode (`!p.unchecked`), which every untrusted program is; for
them nothing changed (no twin is accepted). A trusted program with twins
relies on the compiler (`step::trusted_field_accesses`: no step reaches
a failed unchecked access; TRUSTED.md section 9).

## Implementations

* The compiler emits the twins with `-Xv2_unchecked` or
  `TOIT_V2_UNCHECKED=1` (`ProgramBuilder::create_method_v2` rewrites the
  finished method body); the build compiles the embedded first-party
  programs (`TOIT_SYSTEM_FORMAT2`) with them. Snapshots for untrusted use
  must be compiled without (they would be rejected).
* The core's verified loop runs the twins with the base handlers minus
  the check (`rfields`, `u = true`); the checked loop runs them as their
  checked base; the reference interpreter (`interp/exec2.rs`) too.
* Tables: `V2_OPCODE_LENGTHS` (src/interpreter_v2.h), `OPCODE_LENGTHS2`/
  `OPCODE_NAMES2`, the disassembler (tools/snapshot.toit).
