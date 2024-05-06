// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system

import host.pipe

run-toitp test-args/List toitp-args/List --filter/string?=null -> string:
  i := 0
  snap := test-args[i++]
  toitc := test-args[i++]
  toitp := test-args[i++]

  command-list := [toitp]
  command-list.add-all toitp-args
  command-list.add snap
  if filter: command-list.add filter
  return pipe.backticks command-list

// Extracts the entry names, discarding the index and the location.
extract-entries output/string --max-length/int -> List:
  lines := output.split system.LINE-TERMINATOR
  result := lines.copy 1
  result.filter --in-place: it != ""
  result.map --in-place:
    colon-pos := it.index-of ": "
    (it.copy (colon-pos + 2) (colon-pos + max-length)).trim
  return result
