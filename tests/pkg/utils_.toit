// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.pipe
import system

unzip --source/string --target-dir/string -> none:
  // Unzip the given 'source' zip file into the 'target-dir'.
  exit-value := pipe.run-program ["unzip", "-q", "-d", target-dir, source]
  if exit-value != 0:
    exit-signal := pipe.exit-signal exit-value
    exit-code := pipe.exit-code exit-value
    throw "Failed to unzip '$source' into '$target-dir': $exit-value/$exit-signal"

// A copy of `escape-path` from the utils library of the pkg code.
escape-path path/string -> string:
  if system.platform != system.PLATFORM-WINDOWS:
    return path
  escaped-path := path.replace --all "#" "##"
  [ '<', '>', ':', '"', '|', '?', '*', '\\' ].do:
    escaped-path = escaped-path.replace --all
        string.from-rune it
        "#$(%02X it)"
  if escaped-path.ends-with " " or escaped-path.ends-with ".":
    escaped-path = "$escaped-path#20"
  return escaped-path
