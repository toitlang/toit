<!--
Copyright (C) 2026 Toit contributors.

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; version
2.1 only.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

The license can be found in the file `LICENSE` in the top level
directory of this repository.
-->

# Verified crates

| Path | Content |
|---|---|
| `core/` | Verus-verified interpreter core linked into the VM (see `core/NOTES.md`, `core/TRUSTED.md`). |
| `spec/` | Executable specification of the bytecode machine, verified opcode implementations, format 2 and its verifier (see `spec/DESIGN.md`). |
| `vmverify/` | The format-2 verifier as the VM runs it at untrusted launch (trusted conversion from VM memory, plain Rust, audited), and the one Rust static library the VM links (see `vmverify/README.md`). |
| `check.sh` | The merge gate (below). |
| `TRUSTED.toml` | Allowlist of every place where code is trusted instead of proven. |
| `THEOREMS.txt` | Generated list of what the crates claim, for review. |
| `tools/` | Toit tools (a Toit project; `make download-packages` installs its packages): the escape-hatch scanner `trust_audit.toit` used by `check.sh` (regression test: `tools/tests/trust_audit_test.sh`), the test drivers and their shared `harness.toit`. Run them with `toit run verified/tools/NAME.toit -- ARGS`. |

## The gate: `verified/check.sh`

Run before every merge that touches `verified/` (about 20 s):

```sh
verified/check.sh            # Verus + escape-hatch audit
verified/check.sh --tests    # also layout check, spec tests, sandbox ctests
```

It fails (non-zero exit) unless:

1. **Verus** reports `0 errors` for both crates
   (`verus --crate-type=lib --cfg toit_vcore_hosted src/lib.rs` in `core/`,
   `verus --crate-type=lib src/lib.rs` in `spec/`; `cargo verus verify` if
   only cargo-verus is installed). Verified-item counts and times are
   printed.
2. **Every escape hatch is allowlisted** in `TRUSTED.toml` with a one-line
   justification and the exact count per item; unlisted occurrences, count
   changes, `TODO` justifications and stale entries all fail. The scanner
   tokenizes Rust (comments and strings never count), tracks `verus!`
   regions and attaches attributes to the item that follows. As an
   independent check, every location `verus --no-cheating` rejects must be
   one the scanner flagged. The audit is `tools/trust_audit.toit`; it needs
   a `toit` executable (the build's SDK, else one on the `PATH`).
3. With `--tests`: the audit's regression test
   (`tools/tests/trust_audit_test.sh`), the layout check (`verified_core_layout`),
   `spec/tests/run_tests.sh` and `ctest -R '^tests/sandbox/'` in
   `build/host` (or `--build DIR`); skipped when there is no build.

The checks are named sections: `verified/check.sh --list [--tests]
[--slow]` prints them, `verified/check.sh --only NAME[,NAME...] [--logs
DIR]` runs just those (exit status 3: nothing failed but a section was
skipped). The audit reads the `verus --no-cheating` logs of section
`verus`, so it needs `--logs` of a run that did `verus`. Each section ends
with a line in the summary: passed, FAIL or skipped, and its time.

### The whole gate in parallel: `verified/gate.sh`

`verified/gate.sh [--logs DIR] [--slow] [--allow-skip]` runs the full
merge flow of a checkout, builds included (`make sdk`, `make
download-packages`, `ninja -C build/host`, `build_test_assets`, the ASan
build in `build/asan`, `make TARGET=host32 sdk`), every section of
`check.sh --tests` as `check.sh --only NAME`, and `ctest` of the host build,
as a dependency graph run in parallel (the graph is drawn at the top of
the script). Each part logs to `DIR/NAME.log` (default
`build/gate/<date-time>`); the summary lists each part as passed, FAILED,
skipped or not run (a part it needs did not pass) with its time, and the
exit status is 0 only when every part passed. A section that check.sh
lists but the graph lacks stops the gate before it starts. Ctest failures
other than those in `GATE_CTEST_KNOWN_FAILURES` (default: the multicast
test `tests/udp-reuse-port-test.toit`) fail it; "Not Run" always does.
An interrupt stops every part (each runs in its own session; all its
processes get TERM, then KILL after 30 s).

To gate a commit without touching the current checkout:

```sh
tools/gate-commit.sh COMMIT LOG-DIR    # [--worktree DIR], gate.sh flags after LOG-DIR
```

It creates (or reuses, if clean) the worktree `<main checkout>-gate`,
checks out COMMIT there, links the SDK sources (`tools/worktree-setup.sh
--links-only`) and runs that commit's `verified/gate.sh --logs LOG-DIR`.
Reuse keeps its builds and its matrix work directory; the ccache cache,
cargo's registry, the toit package cache and the matrix tools and memory
queue are shared with other checkouts.

Reported, never failing: allowlisted items that `core/TRUSTED.md` (or
`spec/DESIGN.md` for the spec crate) does not mention, closed and opaque
spec fns, proof fns with an empty body and a non-trivial `ensures`,
`#[verifier::rlimit]` overrides. `THEOREMS.txt` is rewritten on every run;
commit it, and review its diff, whenever it changes.

## Escape-hatch kinds (`kind` in `TRUSTED.toml`)

The list was checked against Verus 0.2026.11.02: by probing which
`#[verifier::...]` names the installed `verus` accepts, by reading vstd
and verus_builtin_macros, and from `verus --help`.

| Kind | Meaning |
|---|---|
| `external_body`, `external`, `external_fn_specification`, `external_type_specification`, `external_trait_specification`, `external_trait_extension`, `external_derive` | Body or item not verified; contract assumed. |
| `assume_specification` | Assumed contract for a foreign function. |
| `axiom` | `axiom fn`: bodiless proof fn (implicitly `external_body`). |
| `uninterp` | `uninterp spec fn`: no assumption by itself, but listed for review. |
| `bodiless_spec` | Spec fn without body or `uninterp` (Verus treats it as `external_body`). |
| `assume`, `admit` | `assume(e)`, `admit()`, `assume_(e)`. |
| `assume_new` | `Ghost::assume_new` / `Tracked::assume_new[_fallback]`. |
| `inline_air` | `inline_air_stmt` (needs `-V allow-inline-air`). |
| `assume_termination`, `exec_allows_no_decreases_clause` | Termination assumed. |
| `truncate` | Cast wraps without proof obligation. |
| `when_used_as_spec`, `ghost_wrapper`, `tracked_*_primitive`, any unknown `verifier::` attribute | Listed so that new attributes fail closed. |
| `verus_internal`, `verus_attr`, `inner_attr` | `#[verus::internal(...)]`, other `#[verus::...]`, module or crate level `#![verifier::...]`. |
| `cfg` | `cfg`/`cfg_attr`/`cfg!` on `verus*` or `toit_vcore_hosted` (Verus sees different code than rustc builds). `use` items are exempt. |
| `unsafe` | Any `unsafe` block, fn or impl. |
| `plain_rust_file`, `plain_rust_item` | Code outside `verus!` (not verified): a whole file, or one item in a file that has `verus!` blocks. |
| `cargo_metadata` | `[package.metadata.verus]` option other than `verify = true`. |

Report-only: `opaque`, `opaque_outside_module`, `rlimit`, `closed`.
Benign (not listed): mode, trigger and prover-selection attributes such as
`spinoff_prover`, `nonlinear`, `integer_ring`, `bit_vector`,
`loop_isolation`, `type_invariant`.

## Changing the trusted base

After adding or removing a trusted item, run
`verified/check.sh --update-allowlist`: it rewrites `TRUSTED.toml`, keeps
existing justifications, and adds new entries with `TODO`, which fail until
replaced by a real justification. Update `core/TRUSTED.md` too.

## Worktrees

`tools/worktree-setup.sh` prepares a fresh git worktree for building (links
the ESP-IDF sources from the main checkout, enables ccache sharing, builds
the SDK and test assets). After it, `source build/worktree-env.sh` before
running `make` by hand.
