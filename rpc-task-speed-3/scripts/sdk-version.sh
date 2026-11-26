#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Rebuilds the worktree's host SDK with the version string VERSION (the one
# the firmware envelopes in bins/ carry, so that their containers accept
# its snapshots). Usage: sdk-version.sh VERSION
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a063f79f8b4a649b9
cd "$WT"
export TMPDIR=$WT/build/tmp
. build/worktree-env.sh
export TOIT_GIT_VERSION=$1
(cd build/host && cmake . > /dev/null)
make sdk
build/host/sdk/bin/toit version
