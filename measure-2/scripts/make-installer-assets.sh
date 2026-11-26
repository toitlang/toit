#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The assets of hwinstall: the untrusted images of progs/untrusted plus
# t-trusted (the trusted-compiled hello, installed as first-party).
set -euo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a341bf2ad86813fd0}
A=/home/flo/work/opentoit-sandbox-artifacts/measure-2
TOIT=$WT/build/host/sdk/bin/toit
U=$A/progs/untrusted
cp "$U/r4-trusted.image" "$U/t-trusted.image"
rm -f "$U/installer.assets"
"$TOIT" tool assets -e "$U/installer.assets" create
for img in "$U"/[a-t]*.image; do
  case $(basename "$img") in x-*) continue ;; esac
  "$TOIT" tool assets -e "$U/installer.assets" add "$(basename "$img" .image)" "$img"
done
ls -l "$U/installer.assets"
