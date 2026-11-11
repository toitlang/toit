#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Runs Frama-C (the first pilot's opam switch, plus frama-clang installed by
# install-tools.sh frama-clang) on a C or C++ file.
#
# Usage: framac.sh FILE [FRAMA-C OPTIONS...]
#   C++ files go through frama-clang; the VM's src/ is on the include path.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
export OPAMROOT="$CXXV_HOME/tools/opam/root"
export PATH="$OPAMROOT/cxxv/bin:$PATH"
file="$1"; shift
why3 config detect > /dev/null 2>&1 || true
start=$(date +%s%N)
case "$file" in
  *.cpp|*.cc)
    # fcshim.h completes frama-clang's libc++; fcshim/pthread.h replaces
    # Frama-C's libc pthread.h (it defines that header's guard first).
    frama-c -machdep "${FC_MACHDEP:-gcc_x86_64}" \
      -cpp-extra-args="-include $ANNOTATED_DIR/fcshim/pthread.h -include $ANNOTATED_DIR/fcshim/fcshim.h -I${FC_SRC:-$REPO_ROOT/src} -DBUILD_64 -std=c++17 ${FC_EXTRA_CPP:-}" \
      "$file" "$@" ;;
  *)
    frama-c "$file" "$@" ;;
esac
status=$?
end=$(date +%s%N)
ms=$(( (end - start) / 1000000 ))
printf 'framac.sh: exit %d, %d.%03d s: %s\n' "$status" $((ms / 1000)) $((ms % 1000)) "$file $*"
exit $status
