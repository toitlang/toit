#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Dumps Clang's JSON AST of the declarations of a C++ file whose qualified
# name contains FILTER, compiled as the host build compiles the VM (the
# flags of src/CMakeLists.txt that change what the code means: the
# language standard and the defines; the include paths of the build).
#
# Usage: clang-ast.sh [--target TRIPLE] [--repo DIR] FILE FILTER OUT
#   FILE is relative to the repository root. Without --target, the host.
# The cxx_render.toit translator calls this; it can also be run by hand.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

TARGET=()
while [ $# -gt 3 ]; do
  case "$1" in
    --target) TARGET=(--target="$2"); shift 2 ;;
    # Another source tree (a mutant: mutant.sh).
    --repo) REPO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    *) echo "clang-ast.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
file="$1"
filter="$2"
out="$3"
CLANG="${CLANGXX:-clang++}"

cd "$REPO_ROOT"
vm_cxx_flags "$REPO_ROOT"
"$CLANG" "${TARGET[@]}" -fsyntax-only "${VM_CXX_FLAGS[@]}" \
  -Xclang -ast-dump=json -Xclang "-ast-dump-filter=$filter" \
  "$file" > "$out"

# An index of the top-level declarations (Clang prints them one after the
# other, a class with its members): name, first byte, end byte. Their keys
# are indented by two spaces, a child's by more.
# Also, for the members and nested declarations of each (as `@ID NAME`),
# which top-level declaration they belong to: a reference spelled inside a
# macro has no source spelling to name its class.
# (String tests, not regular expressions, on every line: gawk's regular
# expressions take seconds on these dumps.)
LC_ALL=C awk 'BEGIN { pos = 0; np = 0; NAME = "  \"name\": \""; ID = "\"id\": \"0x" }
  { line_start = pos; pos += length($0) + 1 }
  $0 == "{" { start = line_start; name = ""; np = 0; record = 0; children = 0 }
  $0 == "  \"kind\": \"CXXRecordDecl\"," { record = 1 }
  # Direct children of a class can be decoded independently. In particular,
  # Primitive contains a deeply nested constant initializer unrelated to its methods.
  record && $0 == "  \"inner\": [" { children = 1 }
  $0 == "  ]" { children = 0 }
  children && $0 == "    {" { member_start = line_start; member = "" }
  children && /^      "name": "/ { member = $0; sub(/^      "name": "/, "", member); sub(/".*$/, "", member) }
  children && /^    },?$/ && member != "" {
    print name "::" member, member_start, line_start + 5
    member = ""
  }
  name == "" && substr($0, 1, 11) == NAME { name = substr($0, 12); sub(/".*$/, "", name) }
  want_kind {
    want_kind = 0
    if ($0 ~ /"kind": "(CXXMethodDecl|VarDecl|EnumConstantDecl|CXXConstructorDecl|CXXDestructorDecl)"/) ids[++np] = id
  }
  index($0, ID) > 3 && prev ~ /^ *[{]$/ { id = $0; sub(/.*"id": "/, "", id); sub(/".*$/, "", id); want_kind = 1 }
  { prev = $0 }
  $0 == "}" {
    n = (name == "" ? "-" : name)
    print n, start, pos
    for (i = 1; i <= np; i++) print "@" ids[i], n
  }
' "$out" > "$out.index"
