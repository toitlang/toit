# 5. Failures raised by the machine

## Problem

Format 1 handles a missing method, a failed `as` check, a block or lambda
called with too few arguments, a bad dynamic global index or initializer
arity, and a missing primitive by pushing extra words and calling a Toit
entry point (`lookup-failure_`, `as-check-failure_`,
`too-few-code-arguments-failure_`, `program-failure_`,
`primitive-lookup-failure_`) that must never return (DESIGN.md item 5).
If it returned, the frame would be misaligned; the verifier has to prove
"never returns" for library code, and the four words pushed by the code
failure path can exceed the reserved stack (P6).

## Alternatives

* Make the failure calls stack-consistent (drop the arguments first) and
  keep calling Toit (P5).
* Raise the exception in the machine (chosen).

## Decision

The machine raises the exception itself: it allocates an `Exception_`
whose value is one of five strings (`LOOKUP_FAILED`, `AS_CHECK_FAILED`,
`CODE_INVOCATION_FAILED`, `INVALID_PROGRAM`, `PRIMITIVE_LOOKUP_FAILED`)
and whose trace is null, and unwinds. The compiler places the strings at
literals 2..6 of every format-2 program, so the machine needs no new
roots. The values are those the Toit failure methods throw, so programs
that catch failures see the same exception value; only the stack trace
is lost for now (the VM can encode one when it raises, as
`encode-error_` does today). The machine also raises `INVALID_PROGRAM`
for the checks format 2 adds (note 12, checked field access).

### The trace and the message in the VM (R2, 2026-11-10)

The spec's exception has a null trace: the trace is outside the model
(nothing in the spec reads it). The VM encodes one when it raises, as
`encode-error_` does for format 1: `toit_v2_allocate_exception`
(src/interpreter_v2.cc) encodes the format-1 message ("an A is not a B",
the selector of a failed lookup, the block arity) from message words the
core passes (receiver, selector offset, class id, bci of the check,
arities) and the frames of the task's stack, and stores the byte array as
the trace. The spec keeps null there: no step reads the field, so the
difference is invisible to the theorem, but the core's refinement
relation must treat field 1 of a machine-raised exception as the one
place where machine and spec may differ (a fresh byte array or null; if
that is awkward to prove, the spec can take the trace as an oracle
value). Obligations of the VM: the trace is a fresh byte array (no
existing object changes), and the encoding reads the message words and
the stack memory-safely. The second is not met today for a forged `List_` receiver
(VM-BUGS.md 4: the error encoder trusts a list's size field).

## Spec and obligations

`raise(p, s, k)` is 10 lines; the failure entry points, their argument
conventions and the "never returns" obligation disappear. No stuck state
remains on these paths. Proven (`x_raise`), including the allocation of
the exception and the unwinding.

## Cost

Failures are cold paths. Allocation of one 2-field object per failure,
as before (format 1 allocated the encoded error). The five failure entry
points become unused (the library keeps them for format 1).
