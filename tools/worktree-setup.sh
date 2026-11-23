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

# Prepares a fresh git worktree of this repository for a host build.
#
# Submodules are not checked out in a worktree. A host build needs only
# third_party/esp-idf/components (mbedtls and lwip sources, see the Makefile's
# check-env/check-mbedtls-config and CMakeLists.txt), so this links that
# directory to the main checkout's copy. The link lives inside the
# uninitialized submodule directory, which git does not look into, so
# `git status` stays clean. The Makefile's submodule check must then be
# skipped with IGNORE_SUBMODULE=1; IDF_PATH keeps its default
# (<worktree>/third_party/esp-idf), which resolves through the link.
#
# Then runs `make sdk`, `make download-packages`, `make build-test-assets`
# and `cmake .` in build/host (so ctest sees every test), using ccache when
# installed with CCACHE_BASEDIR set, so worktrees share cached objects.
#
# Usage: tools/worktree-setup.sh [--links-only] [MAIN-CHECKOUT]
#   MAIN-CHECKOUT defaults to the main worktree from `git worktree list`.
# Afterwards: `source build/worktree-env.sh` before running make by hand.

set -euo pipefail

LINKS_ONLY=0
MAIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --links-only) LINKS_ONLY=1 ;;
    -h|--help) sed -n '/^# Prepares/,/^# Afterwards/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) MAIN="$1" ;;
  esac
  shift
done

WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && git rev-parse --show-toplevel)"
cd "$WT"
if [ -z "$MAIN" ]; then
  MAIN="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
fi
MAIN="$(cd "$MAIN" && pwd)"
echo "Worktree:      $WT"
echo "Main checkout: $MAIN"

STATUS_BEFORE="$(git status --porcelain --untracked-files=no)"

# --- Submodule contents -------------------------------------------------------

IDF_SUB=third_party/esp-idf
SRC="$MAIN/$IDF_SUB/components"
DST="$WT/$IDF_SUB/components"
if [ "$WT" = "$MAIN" ]; then
  echo "This is the main checkout; no links needed."
elif [ -e "$WT/$IDF_SUB/.git" ]; then
  echo "$IDF_SUB is initialized in this worktree; not linking."
else
  if [ ! -f "$SRC/mbedtls/mbedtls/LICENSE" ]; then
    echo "error: $SRC lacks the mbedtls sources;" \
         "run 'git submodule update --init --recursive' in $MAIN." >&2
    exit 1
  fi
  want="$(git ls-tree HEAD "$IDF_SUB" | awk '{print $3}')"
  have="$(git -C "$MAIN/$IDF_SUB" rev-parse HEAD 2> /dev/null || echo unknown)"
  if [ "$want" != "$have" ]; then
    echo "warning: this worktree pins $IDF_SUB at $want, the main checkout has $have."
  fi
  mkdir -p "$WT/$IDF_SUB"
  if [ -L "$DST" ]; then
    if [ "$(readlink "$DST")" != "$SRC" ]; then
      ln -sfn "$SRC" "$DST"
      echo "Relinked $IDF_SUB/components -> $SRC"
    else
      echo "Link $IDF_SUB/components already in place."
    fi
  elif [ -e "$DST" ]; then
    echo "error: $DST exists and is not a link; remove it first." >&2
    exit 1
  else
    ln -s "$SRC" "$DST"
    echo "Linked $IDF_SUB/components -> $SRC"
  fi
fi

# The C++ proof matrix (verified/cxx/annotated/run.sh) reads one FreeRTOS
# header of the EC618 SDK (heap_stats_t); link the SDK's PLAT directory the
# same way when the main checkout has the submodule.
EC618_SUB=third_party/luatos-soc-ec618
EC618_SRC="$MAIN/$EC618_SUB/PLAT"
EC618_DST="$WT/$EC618_SUB/PLAT"
if [ "$WT" != "$MAIN" ] && [ ! -e "$WT/$EC618_SUB/.git" ] && [ -d "$EC618_SRC" ]; then
  want="$(git ls-tree HEAD "$EC618_SUB" | awk '{print $3}')"
  have="$(git -C "$MAIN/$EC618_SUB" rev-parse HEAD 2> /dev/null || echo unknown)"
  if [ "$want" != "$have" ]; then
    echo "warning: this worktree pins $EC618_SUB at $want, the main checkout has $have."
  fi
  mkdir -p "$WT/$EC618_SUB"
  if [ -L "$EC618_DST" ]; then
    ln -sfn "$EC618_SRC" "$EC618_DST"
  elif [ ! -e "$EC618_DST" ]; then
    ln -s "$EC618_SRC" "$EC618_DST"
    echo "Linked $EC618_SUB/PLAT -> $EC618_SRC"
  fi
fi

# --- Environment ----------------------------------------------------------------

ENV_LINES=("export IGNORE_SUBMODULE=1" "export IDF_PATH='$WT/$IDF_SUB'")
if command -v ccache > /dev/null; then
  # CMakeLists.txt picks ccache up by itself. With the base dir set, absolute
  # paths inside the worktree are rewritten to relative ones, and without the
  # directory hash, objects compiled in other worktrees are reused.
  ENV_LINES+=("export CCACHE_BASEDIR='$WT'" "export CCACHE_NOHASHDIR=1")
  echo "ccache: $(command -v ccache) (shared across worktrees via CCACHE_BASEDIR)"
else
  echo "ccache: not installed; builds will not be cached."
fi
mkdir -p "$WT/build"
{
  echo "# Generated by tools/worktree-setup.sh; source before running make."
  printf '%s\n' "${ENV_LINES[@]}"
} > "$WT/build/worktree-env.sh"
# shellcheck disable=SC1091
source "$WT/build/worktree-env.sh"
echo "Environment written to build/worktree-env.sh:"
sed 's/^/  /' "$WT/build/worktree-env.sh" | tail -n +2

STATUS_AFTER="$(git status --porcelain --untracked-files=no)"
if [ "$STATUS_BEFORE" != "$STATUS_AFTER" ]; then
  echo "warning: git status changed:"
  diff <(echo "$STATUS_BEFORE") <(echo "$STATUS_AFTER") || true
fi

if [ "$LINKS_ONLY" = 1 ]; then
  exit 0
fi

# --- Build ----------------------------------------------------------------------

run() {
  echo
  echo "+ $*"
  "$@"
}
run make sdk
run make download-packages
run make build-test-assets
(cd build/host && run cmake .)

if command -v ccache > /dev/null; then
  echo
  ccache -s 2> /dev/null | grep -iE 'hits|misses' | head -4 || true
fi

STATUS_AFTER="$(git status --porcelain --untracked-files=no)"
if [ "$STATUS_BEFORE" != "$STATUS_AFTER" ]; then
  echo "warning: the build changed tracked files:"
  diff <(echo "$STATUS_BEFORE") <(echo "$STATUS_AFTER") || true
fi

cat << EOF

Done. Run tests with: (cd build/host && ctest -j\$(nproc))

Known environmental ctest failures in worktrees (not regressions):
  - version              the version test needs a git-describe version this
                         configuration does not build (not built here).
  - reader               not built in this configuration.
  - udp-reuse-port-test  needs multicast, which the sandbox lacks; fails the
                         same way without any of the sandbox changes.
EOF
