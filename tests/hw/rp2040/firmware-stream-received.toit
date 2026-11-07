// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import system.storage
import .firmware-stream-common show STATE current-digest

main:
  state := storage.Bucket.open --flash STATE
  try:
    digest := current-digest
    expect-equals state["expected"] digest
    expect (digest != state["before"])
    expect-equals 2 state["rejected"]
    ["expected", "before", "rejected"].do: state.remove it
    print "firmware-stream-rp2040: PASS changed image booted and SHA256 verified"
  finally:
    state.close
