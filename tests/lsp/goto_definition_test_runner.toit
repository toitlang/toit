// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .location_compiler_test_runner_base
import expect show *
import .lsp_client show LspClient
import .utils

class GotoDefinitionRunner extends LocationCompilerTestRunner:
  parse_test_lines lines:
    line  := lines[0]
    open  := line.index_of "["
    close := line.index_of "]"
    comma_separated_list := line.copy (open + 1) close
    if comma_separated_list == "": return []

    location_names := comma_separated_list.split ", "
    return location_names

  send_request client/LspClient test_path line reader:
    response := client.send_goto_definition_request --path=test_path line reader
    return response.map: |definition|
      uri := definition["uri"]
      path := client.to_path uri
      range := definition["range"]
      start_line := range["start"]["line"]
      start_char := range["start"]["character"]
      Location path start_line start_char

  check_core_definition core_lib_entry actuals:
    assert: core_lib_entry.starts_with "core."
    target := core_lib_entry.trim --left "core."
    expect
      actuals.any:
        it.path.ends_with "core/$(target).toit"
          and it.column == 0
          and it.line == 0

  check_result actual test_data locations:
    if test_data.size != actual.size:
      print "Not same size:"
      print "test_data: $test_data"
      print "actual: $actual"
    expect_equals test_data.size actual.size

    test_data.do:
      // Special case `core.*`, since we don't want to change the actual
      // core library files.
      if it.starts_with "core.":
        check_core_definition it actual
      else:
        expect (actual.contains locations[it])

main args:
  (GotoDefinitionRunner).run args
