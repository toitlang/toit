#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Copies the device-format2 scripts and programs, pointing them at this
# worktree and artifacts directory.
set -euo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts
for f in fw.sh fw-all.sh suite-envelope.sh make-untrusted.sh decode.sh fwbin-sizes.sh installer-run.sh; do
  sed -e 's#agent-a5fbf012570cfb044#agent-ad2fa912738994022#g' \
      -e 's#opentoit-sandbox-artifacts/device-format2#opentoit-sandbox-artifacts/hardware#g' \
      -e 's#\$A/qemu/progs#$A/progs/suite#g' \
      -e 's#\$A/qemu/untrusted-src#$A/progs/untrusted-src#g' \
      -e 's#\$A/qemu/untrusted#$A/progs/untrusted#g' \
      -- "$A/device-format2/scripts/$f" > "$A/hardware/scripts/$f"
  chmod +x "$A/hardware/scripts/$f"
done
rm -rf "$A/hardware/progs/suite" "$A/hardware/progs/untrusted-src" "$A/hardware/progs/installer-assets"
cp -r "$A/device-format2/qemu/progs" "$A/hardware/progs/suite"
cp -r "$A/device-format2/qemu/untrusted-src" "$A/hardware/progs/untrusted-src"
cp -r "$A/device-format2/qemu/installer-assets" "$A/hardware/progs/installer-assets"
