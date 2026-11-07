// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import system.containers
import system.storage
import .storage-common show verify-persistent

ROOT ::= "toit-rp2040-test/exhaustion"

main:
  bucket := storage.Bucket.open --flash ROOT
  alias := storage.Bucket.open --flash ROOT
  writers := []
  try:
    bucket["value"] = "original"
    bucket["keep"] = #[1, 2, 3]
    // Relocation uses one 4-byte mask per 128 bytes. Each reservation occupies
    // exactly one 4096-byte flash page, without publishing an installed image.
    while true:
      error := catch: writers.add (containers.ContainerImageWriter (4096 + 128))
      if error:
        expect-equals "No space left in flash" error
        break
      expect (writers.size <= 14)
    expect (writers.size > 0)
    expect-throw "OUT_OF_SPACE": bucket["value"] = "rejected"
    if bucket["value"] != "original":
      print "storage-exhaustion: FAIL rejected write changed cached value"
    expect-equals "original" bucket["value"]
    expect-equals "original" alias["value"]
    expect-throw "OUT_OF_SPACE": bucket["new"] = #[4, 5, 6]
    expect-equals null (alias.get "new")
    expect-throw "OUT_OF_SPACE": bucket.remove "keep"
    expect-equals #[1, 2, 3] alias["keep"]
    verify-persistent
  finally:
    writers.do: it.close
    alias.close
    bucket.close
  bucket = storage.Bucket.open --flash ROOT
  try:
    expect-equals "original" bucket["value"]
    expect-equals #[1, 2, 3] bucket["keep"]
    expect-equals null (bucket.get "new")
    // Freed reservations must be usable immediately, including rescan paths.
    bucket["value"] = "replacement"
    expect-equals "replacement" bucket["value"]
    bucket.remove "value"
    bucket.remove "keep"
  finally:
    bucket.close
  verify-persistent
  print "storage-exhaustion: PASS rejected writes, aliases, reopen and reclaimed space"
