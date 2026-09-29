// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

// Updates the page through the 'js' library. The page provides the
// 'setStage' function; everything else uses plain JavaScript.

import js

main:
  js.eval "document.title = 'Toit: DOM demo'"
  size := 21
  30.repeat: | frame |
    rows := List size: | y |
      line := List size: | x |
        dx := x - size / 2
        dy := y - size / 2
        (dx * dx + dy * dy + frame * 4) % 30 < 10 ? "█" : "·"
      line.join ""
    js.call "setStage" [rows.join "\n"]
    sleep --ms=50
  width := js.eval "window.innerWidth"
  print "Rendered 30 frames. The window is $width pixels wide."
