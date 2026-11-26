#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Host checks of the worktree (sections of verified/check.sh run one at a
# time): make sdk, ninja -C build/host, the sandbox ctests, host ctest -j8.
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-ab8ae657bf5edfc00
A=/home/flo/work/opentoit-sandbox-artifacts/s3-ota-soak
cd "$WT" || exit 1
# shellcheck disable=SC1091
. build/worktree-env.sh
export TMPDIR=$WT/build/tmp
export TOIT_GIT_VERSION=v2.0.1-pre.999+s3-ota-soak
make sdk > "$A/logs/host-make-sdk.log" 2>&1; echo "make sdk: $?"
ninja -C build/host -j 10 > "$A/logs/host-ninja.log" 2>&1; echo "ninja build/host: $?"
(cd build/host && cmake . > /dev/null 2>&1)
on_disk=$(ls tests/sandbox/*-test.toit | wc -l)
registered=$(ctest --test-dir build/host -N -R '^tests/sandbox/[^ /]*-test\.toit$' | sed -n 's/^Total Tests: //p')
echo "sandbox tests: $registered registered, $on_disk on disk"
ctest --test-dir build/host -R '^tests/sandbox/' -j 8 --output-on-failure > "$A/logs/host-sandbox-ctest.log" 2>&1
echo "sandbox ctests: $? ($(grep -E 'tests passed' "$A/logs/host-sandbox-ctest.log"))"
ctest --test-dir build/host -j 8 --output-on-failure > "$A/logs/host-ctest.log" 2>&1
echo "host ctest: $? ($(grep -E 'tests passed' "$A/logs/host-ctest.log"))"
sed -n '/The following tests FAILED/,$p' "$A/logs/host-ctest.log" | head -20
