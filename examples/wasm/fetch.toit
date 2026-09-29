// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

// Calls an asynchronous JavaScript function. The calling task blocks until
// the promise settles, while other tasks keep running.

import js

main:
  ticks := 0
  ticker := task::
    while true:
      sleep --ms=5
      ticks++
  // 'fetchJson' is provided by the page.
  data := js.call "fetchJson" ["data.json"]
  ticker.cancel
  print "Fetched: $data"
  print "Languages: $(data["languages"].join ", ")"
  print "The ticker task ran $ticks times while waiting."
