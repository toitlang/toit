// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import system
import system.storage

main arguments/List:
  bucket := storage.Bucket.open --flash "toit-rp2350-test/container"
  try:
    // Confirm arguments and RPC work in a separately installed program.
    token := arguments.is-empty ? "boot" : arguments[0]
    retained := List 40: ByteArray 193 --initial=it
    30.repeat:
      system.process-stats --gc
      retained.size.repeat: | index/int | expect-equals index retained[index][192]
    bucket["result-$token"] = token
    bucket["pid-$token"] = Process.current.id
    bucket["boots"] = (bucket.get "boots" --if-absent=: 0) + 1
    print "container-child: PASS token=$token"
  finally:
    bucket.close
