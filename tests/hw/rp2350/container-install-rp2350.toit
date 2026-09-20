// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import system.assets
import system.containers
import system.storage
import uuid

main:
  bucket := storage.Bucket.open --flash "toit-rp2350-test/container"
  previous := bucket.get "image-id"
  if previous:
    id := uuid.Uuid previous
    if (containers.images.any: it.id == id):
      containers.uninstall id
  bytes := assets.decode["container"]
  writer := containers.ContainerImageWriter bytes.size
  id := null
  try:
    // Split relocation chunks across calls to exercise buffered image writes.
    from := 0
    while from < bytes.size:
      to := min (from + 257) bytes.size
      writer.write bytes[from..to]
      from = to
    id = writer.commit --run-boot
  finally:
    writer.close
  try:
    bucket.remove "result-boot"
    bucket.remove "pid-boot"
    bucket["image-id"] = id.to-byte-array
    child := containers.start id ["rpc"]
    try:
      expect-equals 0 (with-timeout --ms=15_000: child.wait)
    finally:
      child.close
    expect-equals "rpc" bucket["result-rpc"]
    expect (bucket["pid-rpc"] != Process.current.id)
    print "container-install-rp2350: PASS flash image, process, GC, RPC, and exit notification"
  finally:
    bucket.close
