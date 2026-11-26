# verified/gc: the proved copying collector for sandboxed processes

A page-granular Cheney copy in Rust, verified with Verus 0.2026.11.02 for
64- and 32-bit words: milestones M1 and M2 of the plan in
`opentoit-sandbox-artifacts/gc-stage1/README.md` (section 6). Not linked
into the VM yet (M5). The C++ prototype it ports is `src/sandbox_gc.cc`.

- `src/model.rs`: the abstract heap (object ids stable; an object is its
  words, each a reference to an object id or a raw word), the from-space
  description and its well-formedness (`heap_ok`), the encoding.
- `src/layout.rs`: object sizes and reference slots from the raw words
  (and the class table): every heap object kind of the VM (M2).
- `src/space.rs`: the from-space table check and membership search, the
  page source (`PageSource`, a trusted boundary), the disjointness of
  pages from the permissions held.
- `src/cheney.rs`: the ghost state and the Cheney invariant; next-fit
  placement (`place`).
- `src/copy.rs`: the copy with its forwarding header, and that it keeps
  the invariant.
- `src/collect.rs`: the slot visitor, the root loop, the scan over the
  to-space pages.
- `src/statement.rs`: the driver `collect` and its contract `collected`,
  the top-level statement; reachability.
- `src/bridge.rs` (Verus only): `collected` implies the core's
  `gcbridge::collected` and a collection of the spec.
- `tests/collect.rs`: concrete heaps in the VM's layouts, checked against an
  independent reference (reachability, isomorphism up to renumbering, page
  structure).
- `tests/difftest.rs`, `difftest.sh`: the differential test against the C++
  prototype on heap dumps of real programs (TOIT_GC_DUMP, src/sandbox_gc.cc).
- `nopanic/`: a C entry point, linked for riscv32imac and thumbv7m to show
  that no panic machinery survives and to measure the code size.

`TRUSTED.md` lists the trusted base; `TRUSTED.toml` the escape hatches.

Run everything: `verified/gc/check.sh` (Verus for both widths with the
bridge, the escape-hatch audit, the tests for both widths, the no-panic
check). About a minute.
