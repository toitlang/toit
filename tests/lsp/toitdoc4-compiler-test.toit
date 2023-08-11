// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import ...tools.lsp.server.summary
import ...tools.lsp.server.toitdoc-node

import expect show *

main args:
  // We are reaching into the server, so we must not spawn the server as
  // a process.
  run-client-test args --no-spawn-process: test it
  // Since we used '--no-spawn_process' we must exit 0.
  exit 0

DRIVE ::= platform == PLATFORM-WINDOWS ? "c:" : ""
FILE-PATH ::= "$DRIVE/tmp/file.toit"

build-name element klass/Class?=null:
  result := klass ? "$(klass.name)." : ""
  result += element.name
  if element.toitdoc:
    sections := element.toitdoc.sections
    if not sections.is-empty:
      statements := sections.first.statements
      if not statements.is-empty:
        expressions := statements.first.expressions
        if not expressions.is-empty:
          expression := expressions.first
          if expression is Text:
            text := (expression as Text).text
            if text.starts-with "@":
              result += text
  return result

extract-element client/LspClient element-id --path=FILE-PATH -> Method:
  // Reaching into the private state of the server.
  document := client.server.documents_.get-existing-document --path=path
  summary := document.summary
  summary.classes.do: |klass|
    klass.statics.do: if (build-name it klass) == element-id: return it
    klass.constructors.do: if (build-name it klass) == it: return it
    klass.factories.do: if (build-name it klass) == element-id: return it
    klass.methods.do:
      // We don't want to add field getters/setters as the getters would override
      //   the field.
      if not it.is-synthetic:
        if (build-name it klass) == element-id: return it
  summary.functions.do: if (build-name it) == element-id: return it
  throw "not found: $element-id"

test-param-order
    client /LspClient
    element-id / string
    expected-names /List
    --has-diagnostics/bool=false:
  element := extract-element client element-id
  expect-equals expected-names.size element.parameters.size
  element.parameters.do:
    expect-equals expected-names[it.original-index] it.name

TEST-CONTENT ::= """
t1 a b c:
t2 c b a:
t3 --named a [b] [--c]:

class A:
  t1 a b c:  // A.t1
  t2 c b a:  // A.t2
  t3 --named a [b] [--c]:  // A.t3
"""

extract-tests str/string -> List:
  lines := str.split "\n"
  lines = lines.map --in-place: it.trim
  lines = lines.filter --in-place: it != "" and not it.starts-with "class"
  return lines.map: | line |
    comment-index := line.index-of "// "
    override-name := null
    if comment-index >= 0:
      override-name = line[comment-index + 3..]
      line = line[..comment-index - 1].trim
    parts := line.split " "
    name := override-name or parts[0]
    params := parts[1..].map: |param-name|
      param-name = param-name.trim --right ":"  // The method delimiter.
      param-name = param-name.trim --left "["
      param-name = param-name.trim --right "]"
      param-name = param-name.trim --left "--"
      param-name
    [name, params]

test client/LspClient:
  client.send-did-open --path=FILE-PATH --text=""

  client.send-did-change --path=FILE-PATH TEST-CONTENT
  diagnostics := client.diagnostics-for --path=FILE-PATH
  diagnostics.do: print it
  expect diagnostics.is-empty

  tests := extract-tests TEST-CONTENT
  tests.do:
    test-param-order
      client
      it[0]
      it[1]
