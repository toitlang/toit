// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ..ble-benchmarks.requests as benchmark

// Uses actual service RPC without opening a radio transport.
main:
  [20, 512].do: | size/int |
    ["direct", "rpc", "rpc-copy"].do: | mode/string |
      print "DEVICE_RPC START mode=$mode size=$size"
      benchmark.main [mode, "1000", size.stringify]
      print "DEVICE_RPC END mode=$mode size=$size"
  print "DEVICE_RPC COMPLETE cases=6"
