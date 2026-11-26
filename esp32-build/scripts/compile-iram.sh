#!/usr/bin/env bash
# Compiles src/interpreter_run.cc of a source tree with the exact command of
# an ESP-IDF firmware build (from its compile_commands.json) and prints the
# sizes of the IRAM sections and of the functions in them.
# Usage: compile-iram.sh BUILD-DIR SOURCE-ROOT OUT-OBJ [FILE]
#   BUILD-DIR: an idf.py build directory of this worktree (esp32 or esp32c6).
#   SOURCE-ROOT: a tree with src/ and include/ (the worktree or an export of
#   another commit).
set -euo pipefail
B=$1
ROOT=$(cd "$2" && pwd)
OUT=$3
FILE=${4:-src/interpreter_run.cc}
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a11f10728217c321a
CMD=$(grep -B3 "\"file\": \"$WT/$FILE\"" "$B/compile_commands.json" | grep '"command"' | head -1 \
  | sed -e 's/^ *"command": "//' -e 's/",$//' -e 's/\\"/"/g' -e 's/\\\\/\\/g')
[ -n "$CMD" ] || { echo "no compile command for $FILE in $B" >&2; exit 1; }
CMD=${CMD//-I$WT\/src/-I$ROOT\/src}
CMD=${CMD//-I$WT\/include/-I$ROOT\/include}
CMD=$(echo "$CMD" | sed -e "s| -o [^ ]*| -o $OUT|" -e "s| -c [^ ]*| -c $ROOT/$FILE|" -e 's| -MD -MT [^ ]* -MF [^ ]*||')
eval "$CMD ${EXTRA_FLAGS:-}"
TOOL=$(echo "$CMD" | awk '{print $1}')
PREFIX=${TOOL%g++}
"${PREFIX}size" -A "$OUT" | awk '$1 ~ /iram|^\.text|literal/ && $2 > 0'
"${PREFIX}nm" -S -C --size-sort "$OUT" | grep -i ' t ' | tail -8
