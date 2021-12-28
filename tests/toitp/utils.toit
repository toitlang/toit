// Copyright (C) 2020 Toitware ApS. All rights reserved.

import host.pipe

run_toitp test_args/List toitp_args/List -> string:
  i := 0
  snap := test_args[i++]
  toitc := test_args[i++]
  toitp := test_args[i++]

  command_list := [toitc, toitp, snap]
  command_list.add_all toitp_args
  return pipe.backticks command_list

// Extracts the entry names, discarding the index and the location.
extract_entries output/string --max_length/int -> List:
  lines := output.split "\n"
  result := lines.copy 1
  result.filter --in_place: it != ""
  result.map --in_place:
    colon_pos := it.index_of ": "
    (it.copy (colon_pos + 2) (colon_pos + max_length)).trim
  return result
