// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import system.containers
import system.storage
import uuid

main:
  bucket := storage.Bucket.open --flash "toit-rp2350-test/container"
  try:
    with-timeout --ms=15_000:
      while (bucket.get "result-boot") != "boot" or not (bucket.get "pid-boot"):
        sleep --ms=20
    expect (bucket["boots"] >= 2)
    expect (bucket["pid-boot"] != Process.current.id)
    // Leave no auto-starting test container behind for subsequent rig tests.
    id := uuid.Uuid bucket["image-id"]
    containers.uninstall id
    expect (not (containers.images.any: it.id == id))
    print "container-persistence-rp2350: PASS installed image survived OTA, auto-started, and uninstalled"
  finally:
    bucket.close
