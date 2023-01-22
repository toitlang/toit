// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import ...tools.lsp.server.summary
import ...tools.lsp.server.toitdoc_node

import expect show *

main args:
  // We are reaching into the server, so we must not spawn the server as
  // a process.
  run_client_test args --no-spawn_process: test it
  // Since we used '--no-spawn_process' we must exit 0.
  exit 0

DRIVE ::= platform == PLATFORM_WINDOWS ? "C:" : ""
FILE_PATH ::= "$DRIVE/tmp/file.toit"

build_name element klass/Class?=null:
  result := klass ? "$(klass.name)." : ""
  result += element.name
  if element.toitdoc:
    sections := element.toitdoc.sections
    if not sections.is_empty:
      statements := sections.first.statements
      if not statements.is_empty:
        expressions := statements.first.expressions
        if not expressions.is_empty:
          expression := expressions.first
          if expression is Text:
            text := (expression as Text).text
            if text.starts_with "@":
              result += text
  return result

extract_element client/LspClient element_id --path=FILE_PATH -> Method:
  // Reaching into the private state of the server.
  document := client.server.documents_.get_existing_document --path=path
  summary := document.summary
  summary.classes.do: |klass|
    klass.statics.do: if (build_name it klass) == element_id: return it
    klass.constructors.do: if (build_name it klass) == it: return it
    klass.factories.do: if (build_name it klass) == element_id: return it
    klass.methods.do:
      // We don't want to add field getters/setters as the getters would override
      //   the field.
      if not it.is_synthetic:
        if (build_name it klass) == element_id: return it
  summary.functions.do: if (build_name it) == element_id: return it
  throw "not found: $element_id"

test_param_order
    client /LspClient
    element_id / string
    expected_names /List
    --has_diagnostics/bool=false:
  element := extract_element client element_id
  expect_equals expected_names.size element.parameters.size
  element.parameters.do:
    expect_equals expected_names[it.original_index] it.name

TEST_CONTENT ::= """
t1 a b c:
t2 c b a:
t3 --named a [b] [--c]:

class A:
  t1 a b c:  // A.t1
  t2 c b a:  // A.t2
  t3 --named a [b] [--c]:  // A.t3
"""

extract_tests str/string -> List:
  lines := str.split "\n"
  lines = lines.map --in_place: it.trim
  lines = lines.filter --in_place: it != "" and not it.starts_with "class"
  return lines.map: | line |
    comment_index := line.index_of "// "
    override_name := null
    if comment_index >= 0:
      override_name = line[comment_index + 3..]
      line = line[..comment_index - 1].trim
    parts := line.split " "
    name := override_name or parts[0]
    params := parts[1..].map: |param_name|
      param_name = param_name.trim --right ":"  // The method delimiter.
      param_name = param_name.trim --left "["
      param_name = param_name.trim --right "]"
      param_name = param_name.trim --left "--"
      param_name
    [name, params]

test client/LspClient:
  client.send_did_open --path=FILE_PATH --text=""

  client.send_did_change --path=FILE_PATH TEST_CONTENT
  diagnostics := client.diagnostics_for --path=FILE_PATH
  diagnostics.do: print it
  expect diagnostics.is_empty

  tests := extract_tests TEST_CONTENT
  tests.do:
    test_param_order
      client
      it[0]
      it[1]
