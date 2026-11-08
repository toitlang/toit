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

## Spec and obligations

`raise(p, s, k)` is 10 lines; the failure entry points, their argument
conventions and the "never returns" obligation disappear. No stuck state
remains on these paths. Proven (`x_raise`), including the allocation of
the exception and the unwinding.

## Cost

Failures are cold paths. Allocation of one 2-field object per failure,
as before (format 1 allocated the encoded error). The five failure entry
points become unused (the library keeps them for format 1).
