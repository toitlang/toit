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

# Gates a commit in a worktree of its own, without touching the checkout
# this is run from.
#
# Creates the gate worktree (detached at COMMIT), or reuses it: it must
# have no changes to tracked files, and is then checked out at COMMIT.
# Runs tools/worktree-setup.sh --links-only in it, then its
# verified/gate.sh (the commit's own: the commit must have one) with the
# logs in LOG-DIR. One gate run per gate worktree at a time (a lock).
#
# Reusing the worktree keeps its builds (incremental after the first run)
# and the residual C++ matrix's per-checkout work directory. Shared with
# other checkouts: the ccache cache (CCACHE_BASEDIR, see
# tools/worktree-setup.sh), cargo's registry, the toit package cache, the
# ESP-IDF and EC618 SDK sources (links into the main checkout, read only),
# the matrix's tools and its machine-wide model-checker memory queue.
# Not shared: the build directories, the 32-bit Verus libraries
# (build/verus-*), the matrix's renderings and logs.
#
# Usage: tools/gate-commit.sh [--worktree DIR] COMMIT LOG-DIR [GATE-ARGS...]
#   DIR defaults to <main checkout>-gate next to the main checkout.
#   GATE-ARGS go to verified/gate.sh (--slow, --allow-skip).
# Exit status: that of verified/gate.sh (0 when every part passed).

set -u -o pipefail

WT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) shift; WT="$1" ;;
    -h|--help) sed -n '/^# Gates a commit/,/^# Exit status/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
  shift
done
if [ $# -lt 2 ]; then
  echo "Usage: tools/gate-commit.sh [--worktree DIR] COMMIT LOG-DIR [GATE-ARGS...]" >&2
  exit 2
fi
COMMIT_ARG="$1"
LOG_DIR="$2"
shift 2

HERE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && git rev-parse --show-toplevel)"
MAIN="$(git -C "$HERE_REPO" worktree list --porcelain | sed -n '1s/^worktree //p')"
COMMIT="$(git -C "$HERE_REPO" rev-parse --verify "$COMMIT_ARG^{commit}")" || exit 2
[ -n "$WT" ] || WT="$MAIN-gate"
mkdir -p "$LOG_DIR"
LOG_DIR="$(cd "$LOG_DIR" && pwd)"

if [ -e "$WT/.git" ]; then
  if [ "$(git -C "$WT" rev-parse --git-common-dir 2> /dev/null | xargs -I{} realpath {})" \
       != "$(realpath "$(git -C "$HERE_REPO" rev-parse --git-common-dir)")" ]; then
    echo "error: $WT is not a worktree of this repository" >&2
    exit 2
  fi
else
  echo "Creating the gate worktree $WT"
  git -C "$HERE_REPO" worktree add --detach "$WT" "$COMMIT" || exit 2
fi
WT="$(cd "$WT" && pwd)"

mkdir -p "$WT/build"
exec 8> "$WT/build/.gate-commit.lock"
if ! flock -n 8; then
  echo "waiting for another gate run in $WT"
  flock 8
fi

if [ -n "$(git -C "$WT" status --porcelain --untracked-files=no)" ]; then
  echo "error: the gate worktree $WT has changes to tracked files; not touching it:" >&2
  git -C "$WT" status --short --untracked-files=no >&2
  exit 2
fi
git -C "$WT" checkout --quiet --detach "$COMMIT" || exit 2
if [ ! -x "$WT/verified/gate.sh" ]; then
  echo "error: $COMMIT has no verified/gate.sh (it predates the parallel gate); run verified/check.sh there" >&2
  exit 2
fi

{
  echo "commit: $COMMIT"
  git -C "$WT" log -1 --format='%s (%an, %ad)' "$COMMIT"
  echo "worktree: $WT"
  echo "started: $(date -Is)"
} > "$LOG_DIR/commit.txt"
cat "$LOG_DIR/commit.txt"

"$WT/tools/worktree-setup.sh" --links-only "$MAIN" > "$LOG_DIR/worktree-setup.log" 2>&1 || {
  cat "$LOG_DIR/worktree-setup.log" >&2
  exit 2
}
"$WT/verified/gate.sh" --logs "$LOG_DIR" "$@"
status=$?
echo "finished: $(date -Is), exit status $status" >> "$LOG_DIR/commit.txt"
exit $status
