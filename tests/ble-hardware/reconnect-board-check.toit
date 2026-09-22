// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.json
import host.file
import .reconnect-check as checker

main args/List:
  if not 2 <= args.size <= 3: throw "Usage: reconnect-board-check CENTRAL_LOG PEER_LOG [CYCLES]"
  result := checker.check-boards (file.read-contents args[0]).to-string-non-throwing (file.read-contents args[1]).to-string-non-throwing
      --cycles=(args.size == 3 ? (int.parse args[2]) : 1000)
  print (json.encode result).to-string-non-throwing
