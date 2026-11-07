// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import system.containers
import system.storage
import uuid
import io.stdio

main:
  bucket := storage.Bucket.open --flash "toit-rp2040-test/container"
  try:
    id := uuid.Uuid bucket["image-id"]
    info := (containers.images.filter: it.id == id).first
    expect-equals 12345 info.data
    child := containers.start id ["after-update"]
    try:
      expect-equals 0 (with-timeout --ms=15_000: child.wait)
    finally:
      child.close
    // Let the host verify the independently auto-started child before removal.
    print "container-persistence-rp2040: READY cleanup"
    expect-equals "cleanup\n" (stdio.stdin.read-bytes 8).to-string
    containers.uninstall id
    expect (not (containers.images.any: it.id == id))
    bucket.remove "image-id"
  finally:
    bucket.close
  print "container-persistence-rp2040: PASS image, metadata, assets, firmware replacement and uninstall"
