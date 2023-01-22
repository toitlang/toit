// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file
import host.pipe
import reader show BufferedReader
import .lsp_client show LspClient run_client_test
import .utils

is_absolute_ path/string -> bool:
  if path.starts_with "/": return true
  if platform != PLATFORM_WINDOWS: return false
  return path.size > 1 and path[1] == ':'

abstract class LocationCompilerTestRunner:
  abstract parse_test_lines lines
  abstract send_request client/LspClient test_path/string line/int column/int
  abstract check_result actual test_data locations

  run args:
    test_path := args[0]
    args = args.copy 1
    if not is_absolute_ test_path:
      throw "test-path must be absolute (and canonicalized): $test_path"

    locations := extract_locations test_path

    run_client_test args: test it test_path locations
    run_client_test --use_toitlsp args: test it test_path locations

  test client/LspClient test_path/string locations/Map:
    content := (file.read_content test_path).to_string

    client.send_did_open --path=test_path --text=content

    lines := (content.trim --right "\n").split "\n"
    lines = lines.map --in_place: it.trim --right "\r"
    for i := 0; i < lines.size; i++:
      line := lines[i]
      is_test_line := false
      if line.starts_with "/*" and not line.starts_with "/**":
        test_line_index := i - 1
        test_line := lines[test_line_index]
        if not line.contains "^":
          // This should only happen if we want to have a test/location at the
          // beginning of the line (or if this is a location entry).
          i++
          if i == lines.size: continue
          line = lines[i]
        if not line.contains "^": continue

        column := line.index_of "^"

        range_end := (line.index_of --last "~") + 1
        alternative_content := null

        if not range_end == 0:
          replacement_line := (test_line.copy 0 column) + (test_line.copy range_end)
          alternative_content = combine_and_replace lines test_line_index replacement_line

        test_data_lines := []
        i++
        while not lines[i].starts_with "*/":
          test_data_lines.add lines[i++]
        test_data := parse_test_lines test_data_lines

        client.send_did_change --path=test_path content
        response := send_request client test_path test_line_index column
        check_result response test_data locations

        if alternative_content != null:
          client.send_did_change --path=test_path alternative_content
          alternative_response := send_request client test_path test_line_index column
          check_result alternative_response test_data locations
