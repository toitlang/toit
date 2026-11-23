#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# The license can be found in the file `LICENSE` in the top level
# directory of this repository.

# No Python in the repository: the tooling is Toit, shell, CMake, or Rust
# inside verified/. Fails when the git checkout ROOT tracks
#   - a *.py or *.pyc file outside tools/ci/ (upstream's CI helpers) and
#     third_party/, or
#   - a shell script under verified/ (*.sh, or a file with a sh or bash
#     shebang) that invokes python (a command word python, python3,
#     python3.14, ..., also after a path or `env`; comment lines do not
#     count), or a file under verified/ with a python shebang.
#
# Usage: no_python_check.sh [ROOT]   (default: the repository of this script)
#        no_python_check.sh --self-test
# Exit status 0 when clean, 1 with the offending files listed, 2 on usage or
# when ROOT is not a git checkout.

set -uo pipefail

check() {
  local root="$1" found=0 files f
  if ! files=$(git -C "$root" ls-files -- '*.py' '*.pyc' ':!:tools/ci/' ':!:third_party/'); then
    echo "no_python_check: $root is not a git checkout" >&2
    return 2
  fi
  if [ -n "$files" ]; then
    echo "Python files (convert them to Toit or shell):"
    printf '  %s\n' $files
    found=1
  fi
  local scripts=()
  while IFS= read -r -d '' f; do
    [ -f "$root/$f" ] || continue
    local first
    first=$(head -n 1 "$root/$f" 2> /dev/null | tr -d '\0')
    if [[ "$first" =~ ^#!.*pytho[n] ]]; then
      scripts+=("$f (a Python shebang)")
    elif [[ "$f" == *.sh ]] || [[ "$first" =~ ^#!.*(/|[[:space:]])(ba)?sh([[:space:]]|$) ]]; then
      # Drop comment lines; look for python as a command word.
      if grep -v '^[[:space:]]*#' "$root/$f" \
          | grep -qE '(^|[^A-Za-z0-9_.-])pytho[n][0-9.]*([[:space:]]|$|[;&|)])'; then
        scripts+=("$f")
      fi
    fi
  done < <(git -C "$root" ls-files -z -- verified)
  if [ ${#scripts[@]} -gt 0 ]; then
    echo "Scripts under verified/ that run Python:"
    printf '  %s\n' "${scripts[@]}"
    found=1
  fi
  if [ $found -eq 0 ]; then
    echo "no Python: no tracked *.py/*.pyc outside tools/ci/ and third_party/, no script under verified/ runs python"
  fi
  return $found
}

self_test() {
  # The interpreter's name is spelled indirectly here so that this script
  # passes its own check.
  local tmp status=0 P=pytho
  P+=n
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/no-python-check.XXXXXX") || return 2
  trap 'rm -rf "$tmp"' RETURN
  # expect NAME STATUS: runs the check on $tmp/NAME, requires the status.
  expect() {
    local got
    check "$tmp/$1" > "$tmp/$1.out" 2>&1
    got=$?
    if [ "$got" -eq "$2" ]; then
      echo "ok    self-test $1 (exit $got)"
    else
      echo "FAIL  self-test $1: exit $got, expected $2"; sed 's/^/      /' "$tmp/$1.out"
      status=1
    fi
  }
  repo() {
    mkdir -p "$tmp/$1"
    git -C "$tmp/$1" init -q
    shift
  }
  add() {  # REPO PATH CONTENT
    mkdir -p "$(dirname "$tmp/$1/$2")"
    printf '%s\n' "$3" > "$tmp/$1/$2"
    git -C "$tmp/$1" add -- "$2"
  }
  repo clean
  add clean tools/ci/archive.py 'print(1)'
  add clean third_party/x/setup.py 'print(1)'
  add clean verified/a.sh "# Runs no ${P}3 here; $P is mentioned in a comment."
  add clean verified/b.sh 'echo pythonic; ./mypython3.sh; python_check=1'
  add clean verified/c.toit 'python-str x'
  expect clean 0
  repo py
  add py verified/x/tool.py 'print(1)'
  expect py 1
  repo pyc
  add pyc verified/x/__pycache__/tool.cpython-314.pyc 'x'
  expect pyc 1
  repo nested-ci
  add nested-ci src/tools/ci/x.py 'print(1)'
  expect nested-ci 1
  for call in "${P}3 - \"\$1\" <<EOF" "  exec ${P}3.14 x" "x=\$($P -c 1)" "/usr/bin/${P}3 x" "env ${P}3 x" "a && ${P}3" "run ${P}3; echo"; do
    local name="call-$((++n))"
    repo "$name"
    add "$name" verified/cxx/run.sh "$call"
    expect "$name" 1
  done
  repo shebang
  add shebang verified/tool "#!/usr/bin/env ${P}3"
  expect shebang 1
  repo bash-shebang
  add bash-shebang verified/tool "#!/usr/bin/env bash"$'\n'"${P}3 x"
  expect bash-shebang 1
  repo outside
  add outside tests/qemu/build.sh "$P idf.py build"
  expect outside 0
  # This script itself, as verified/tools/no_python_check.sh.
  repo self
  add self verified/tools/no_python_check.sh "$(cat "${BASH_SOURCE[0]}")"
  expect self 0
  expect not-a-repo 2
  return $status
}

case "${1:-}" in
  --self-test) n=0; self_test ;;
  -*) echo "usage: no_python_check.sh [ROOT] | --self-test" >&2; exit 2 ;;
  *) check "${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}" ;;
esac
