# Red-team review, round 1 (2026-11-11)

Independent agent, no access to design notes or audit reports until the end.
About half an hour of work, 104 tool calls: a shallow first pass.

Verdict: the sandbox was not broken. No memory corruption, VM crash,
isolation breach or privilege confusion found.

What was actually attacked:
- `bitmap.blit` and `byte_zap`: 111,375 adversarial calls (extreme, negative
  and overflowing strides, all operations, slices as destination, aliasing):
  no out-of-bounds access under ASan (`repro/blit-attack.toit`).
- Broad hostile primitive arguments from an untrusted container
  (`repro/prim-hostility.toit`): clean under ASan.
- Code review of byte-content access, endian and copy primitives, the method
  table decoder, the conversion from VM memory, and the message gate.
- The builders' mutation fuzzer on an ASan+UBSan build: 6,453 mutants, no real
  crash.

Observation outside the sandbox claim: signed-overflow undefined behaviour in
the C++ integer primitives and the C++ interpreter (`large_integer_add`,
`large_integer_subtract`, `smi_multiply`, interpreter_run.cc), reachable only
from trusted code (`repro/trusted-bigint-ub.toit`, `repro/smi-mul-ub.toit`);
the Rust core does not have it.

NOT done in this round (the brief asked for it): hand-crafted bytecode and
certificates (type confusion, frame and unwinding manipulation, crafted
handler records), lifecycle attacks (install, verdict, restart), service-layer
attacks beyond reading the code, resource exhaustion. A second round covers
these.
