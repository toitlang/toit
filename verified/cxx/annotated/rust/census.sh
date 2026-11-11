#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# A census of the trusted Rust items of crate core (verified/TRUSTED.toml)
# for the raw-memory trial (README, "The Rust raw-memory layer"): per kind,
# and, for the external_body functions of verified/core/src, how many
# bodies use a right shift (VeriFast 26.10's Rust front end: "Todo:
# BinOp::Shr"), an integer-to-pointer cast (Verus: none; needs a rewrite
# with vstd::raw_ptr), or a call into C++ (an FFI function: a contract, not
# a body to verify).

set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
echo "TRUSTED.toml, crate core, by kind:"
awk '/^\[\[trusted\]\]/ { c = "" } /^crate = / { c = $3 } /^kind = / { if (c == "\"core\"") k[$3]++ }
     END { for (x in k) printf "  %-24s %d\n", x, k[x] }' "$root/verified/TRUSTED.toml" | sort
echo "external_body functions in verified/core/src:"
for f in "$root"/verified/core/src/*.rs; do
  awk -v name="$(basename "$f")" '
    /#\[verifier::external_body\]/ { inb = 1; body = ""; n++; next }
    inb { body = body $0 "\n" }
    inb && (/^    }$/ || /^}$/) {
      if (body ~ />>/) shr++
      if (body ~ /as \*(const|mut)/) ptr++
      if (body ~ /toit_v2_|unsafe \{ *[a-z_]+\(/) ffi++
      inb = 0
    }
    END { if (n) printf "  %-16s %3d bodies: %3d with >>, %3d with pointer casts, %3d FFI calls\n", name, n, shr, ptr, ffi }
  ' "$f"
done
