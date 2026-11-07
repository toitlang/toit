// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import system.assets
import system.containers
import system.storage
import uuid
import rp2040
import .storage-common show verify-persistent

ROOT ::= "toit-rp2040-test/container"

main:
  bucket := storage.Bucket.open --flash ROOT
  try:
    previous := bucket.get "image-id"
    if previous:
      id := uuid.Uuid previous
      expect (containers.images.any: it.id == id)
      child := containers.start id ["after-reset"]
      try:
        expect-equals 0 (with-timeout --ms=15_000: child.wait)
      finally:
        child.close
      print "container-install-rp2040: PASS installed image and assets survived reset"
      return
    // The registry is only 56 KiB. Reclaim our earlier large storage fixtures
    // before installing this program. The host runner restores them afterward.
    // No buckets or regions outside the named test namespace are removed.
    verify-persistent
    persistent := storage.Bucket.open --flash "toit-rp2040-test/persistent"
    try:
      ["large", "small", "marker"].do: persistent.remove it
    finally:
      persistent.close
    storage.Region.delete --flash "toit-rp2040-test/region"
    envelope := storage.Bucket.open --flash "toit-rp2040-test/envelope"
    try:
      envelope.remove "success"
    finally:
      envelope.close
    bytes := assets.decode["container"]
    writer := containers.ContainerImageWriter bytes.size
    id := null
    try:
      from := 0
      while from < bytes.size:
        to := min (from + 257) bytes.size
        writer.write bytes[from..to]
        from = to
      id = writer.commit --run-boot --data=12345
    finally:
      writer.close
    bucket["image-id"] = id.to-byte-array
    child := containers.start id ["rpc"]
    try:
      expect-equals 0 (with-timeout --ms=15_000: child.wait)
    finally:
      child.close
    print "container-install-rp2040: PASS streamed image, arguments and exit notification; resetting"
    rp2040.reset
  finally:
    bucket.close
