// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import ...tools.lsp.server.summary
import ...tools.lsp.server.toitdoc_node
import .utils

import host.directory
import expect show *

main args:
  // We are reaching into the server, so we must not spawn the server as
  // a process.
  run_client_test args --no-spawn_process: test it
  // Since we used '--no-spawn_process' we must exit 0.
  exit 0

FILE_URI ::= "untitled:/non_existent.toit"

global_thunk name/string -> ToitdocRef:
  return ToitdocRef
      --text=name
      --kind=ToitdocRef.GLOBAL_METHOD
      --module_uri=FILE_URI
      --holder=null
      --name=name
      --shape=Shape
          --arity=0
          --total_block_count=0
          --named_block_count=0
          --is_setter=false
          --names=[]

expect_statement_equal expected/Statement actual/Statement:
  if expected is CodeSection:
    expect actual is CodeSection
    expect_equals
        (expected as CodeSection).text
        (actual as CodeSection).text
  else if expected is Itemized:
    expect actual is Itemized
    expected_items := (expected as Itemized).items
    actual_items := (actual as Itemized).items
    expect_equals expected_items.size actual_items.size
    expected_items.size.repeat:
      expected_statements := expected_items[it].statements
      actual_statements := actual_items[it].statements
      expect_equals expected_statements.size actual_statements.size
      expected_statements.size.repeat:
        expect_statement_equal expected_statements[it] actual_statements[it]
  else:
    expect expected is Paragraph
    expect actual is Paragraph
    expected_expressions := (expected as Paragraph).expressions
    actual_expressions := (actual as Paragraph).expressions
    expect_equals expected_expressions.size actual_expressions.size
    expected_expressions.size.repeat:
      expected_expression := expected_expressions[it]
      actual_expression := actual_expressions[it]
      if expected_expression is Text:
        expect actual_expression is Text
        expect_equals expected_expression.text actual_expression.text
      else if expected_expression is Code:
        expect actual_expression is Code
        expect_equals expected_expression.text actual_expression.text
      else:
        expect actual_expression is ToitdocRef
        expect_equals expected_expression.text actual_expression.text
        expect_equals expected_expression.kind actual_expression.kind
        expect_equals expected_expression.module_uri actual_expression.module_uri
        expect_equals expected_expression.holder actual_expression.holder
        expect_equals expected_expression.name actual_expression.name
        if expected_expression.shape:
          expected_shape := expected_expression.shape
          actual_shape := actual_expression.shape
          expect_equals expected_shape.arity actual_shape.arity
          expect_equals expected_shape.total_block_count actual_shape.total_block_count
          expect_equals expected_shape.named_block_count actual_shape.named_block_count
          expect_equals expected_shape.is_setter actual_shape.is_setter
          expect_list_equals expected_shape.names actual_shape.names
        else:
          expect_null actual_expression.shape


test_toitdoc client/LspClient str/string expected / Contents:
  client.send_did_change --uri=FILE_URI str
  (client.diagnostics_for --uri=FILE_URI).do: print it
  expect (client.diagnostics_for --uri=FILE_URI).is_empty
  // Reaching into the private state of the server.
  document := client.server.documents_.get_existing_document --uri=FILE_URI
  summary := document.summary
  actual := summary.toitdoc
  expect_equals expected.sections.size actual.sections.size
  actual.sections.size.repeat:
    expected_section := expected.sections[it]
    actual_section := actual.sections[it]
    expect_equals expected_section.title actual_section.title
    expect_equals expected_section.statements.size actual_section.statements.size
    expected_section.statements.size.repeat:
      expected_statement := expected_section.statements[it]
      actual_statement := actual_section.statements[it]
      expect_statement_equal expected_statement actual_statement

test client/LspClient:
  client.send_did_open --uri=FILE_URI --text=""

  test_toitdoc
      client
      """
      /**
      Simple
      */
      """
      Contents [
        Section null
          [
            Paragraph [
              Text "Simple"
            ]
          ]
      ]

  test_toitdoc
      client
      """
      /**
      Simple
        multiline
      */
      """
      Contents [
        Section null
          [
            Paragraph [
              Text "Simple multiline"
            ]
          ]
      ]

  test_toitdoc
      client
      """
        /**
        Indented
        */
      """
      Contents [
        Section null
          [
            Paragraph [
              Text "Indented"
            ]
          ]
      ]

  test_toitdoc
      client
      """
        /**
        Indented
          multiline
        */
      """
      Contents [
        Section null
          [
            Paragraph [
              Text "Indented multiline"
            ]
          ]
      ]

  test_toitdoc
      client
      """
        /**
        Indented \$ref \$(ref)
        */

        ref:
      """
      Contents [
        Section null
          [
            Paragraph [
              Text "Indented ",
              global_thunk "ref",
              Text " ",
              global_thunk "ref",
            ]
          ]
      ]

  test_toitdoc
      client
      """
        /**
        Indented `code`
        */
      """
      Contents [
        Section null
          [
            Paragraph [
              Text "Indented ",
              Code "code",
            ]
          ]
      ]

  test_toitdoc
      client
      """
        /**
        Indented

        ```
        Code section
        ```

        another paragraph
        */
      """
      Contents [
        Section null
          [
            Paragraph [ Text "Indented" ],
            CodeSection "\nCode section\n",
            Paragraph [ Text "another paragraph" ],
          ]
      ]

  test_toitdoc
      client
      """
        /**
        # Section1
        Indented

        ```
        Code section
        ```

        another paragraph
        */
      """
      Contents [
        Section "Section1"
          [
            Paragraph [ Text "Indented" ],
            CodeSection "\nCode section\n",
            Paragraph [ Text "another paragraph" ],
          ]
      ]

  test_toitdoc
      client
      """
        /**
        unnamed section

        # Section1
        Indented

        ```
        Code section
        ```

        another paragraph
        */
      """
      Contents [
        Section null
          [
            Paragraph [ Text "unnamed section" ],
          ],
        Section "Section1"
          [
            Paragraph [ Text "Indented" ],
            CodeSection "\nCode section\n",
            Paragraph [ Text "another paragraph" ],
          ]
      ]

  test_toitdoc
      client
      """
        /**
        unnamed section `code` and \$ref and \$(ref) followed
          by an indentation

        # Section1
        Indented

        ```
        Code section
        ```

        another paragraph
        */

        ref:
      """
      Contents [
        Section null
          [
            Paragraph [
              Text "unnamed section ",
              Code "code",
              Text " and ",
              global_thunk "ref",
              Text " and ",
              global_thunk "ref",
              Text " followed by an indentation",
            ],
          ],
        Section "Section1"
          [
            Paragraph [ Text "Indented" ],
            CodeSection "\nCode section\n",
            Paragraph [ Text "another paragraph" ],
          ]
      ]

  test_toitdoc
      client
      """
        /**
        A

        B
          C
        */
      """
      Contents [
        Section null
          [
            Paragraph [
              Text "A",
            ],
            Paragraph [
              Text "B C",
            ],
          ],
      ]

  test_toitdoc
      client
      """
        /**
        - 1
        - 2
        - 3

        - 4

        para

        * 1
        * 2
        * 3
        */
      """
      Contents [
        Section null
          [
            Itemized [
              Item [ Paragraph [Text "1"] ],
              Item [ Paragraph [Text "2"] ],
              Item [ Paragraph [Text "3"] ],
              Item [ Paragraph [Text "4"] ],
            ],
            Paragraph [
              Text "para",
            ],
            Itemized [
              Item [ Paragraph [Text "1"] ],
              Item [ Paragraph [Text "2"] ],
              Item [ Paragraph [Text "3"] ],
            ],
          ],
      ]

  test_toitdoc
      client
      """
        /**
        - 1
          - nest1
          - nest2
        - 2
        */
      """
      Contents [
        Section null
          [
            Itemized [
              Item [
                Paragraph [Text "1"],
                Itemized [
                  Item [ Paragraph [Text "nest1"] ],
                  Item [ Paragraph [Text "nest2"] ],
                ]
              ],
              Item [ Paragraph [Text "2"] ],
            ],
          ],
      ]

  test_toitdoc
      client
      """
        /**
        - 1
          - nest1
          - nest2
         /* weird indentation follows. also a test with comments. */
         ```
         code section
         ```
          ```
          correct indent
          ```
        - 2
        */
      """
      Contents [
        Section null
          [
            Itemized [
              Item [
                Paragraph [Text "1"],
                Itemized [
                  Item [ Paragraph [Text "nest1"] ],
                  Item [ Paragraph [Text "nest2"] ],
                ],
                CodeSection "\ncode section\n",
                CodeSection "\ncorrect indent\n",
              ],
              Item [ Paragraph [Text "2"] ],
            ],
          ],
      ]

  test_toitdoc
      client
      """
        /**
        Updates the value of the given \$key.

        If this instance contains the \$key, calls the \$updater with the current value,
          and replaces the old value with the result. Returns the result of the call.

        If this instance does not contain the \$key, calls \$if_absent instead, and
          stores the result of the call in this instance. Returns the result of the call.
        */

      key:
      updater:
      if_absent:
      """
      Contents [
        Section null
          [
            Paragraph [
              Text "Updates the value of the given ",
              global_thunk "key",
              Text ".",
            ],
            Paragraph [
              Text "If this instance contains the ",
              global_thunk "key",
              Text ", calls the ",
              global_thunk "updater",
              Text " with the current value, and replaces the old value with the result. Returns the result of the call.",
            ],
            Paragraph [
              Text "If this instance does not contain the ",
              global_thunk "key",
              Text ", calls ",
              global_thunk "if_absent",
              Text " instead, and stores the result of the call in this instance. Returns the result of the call.",
            ],
          ],
      ]

  test_toitdoc
      client
      """
        /**
        - Updates the value of the given \$key.

          If this instance contains the \$key, calls the \$updater with the current value,
            and replaces the old value with the result. Returns the result of the call.

          If this instance does not contain the \$key, calls \$if_absent instead, and
            stores the result of the call in this instance. Returns the result of the call.
        - 2
        */

      key:
      updater:
      if_absent:
      """
      Contents [
        Section null
          [
            Itemized [
              Item [
                Paragraph [
                  Text "Updates the value of the given ",
                  global_thunk "key",
                  Text ".",
                ],
                Paragraph [
                  Text "If this instance contains the ",
                  global_thunk "key",
                  Text ", calls the ",
                  global_thunk "updater",
                  Text " with the current value, and replaces the old value with the result. Returns the result of the call.",
                ],
                Paragraph [
                  Text "If this instance does not contain the ",
                  global_thunk "key",
                  Text ", calls ",
                  global_thunk "if_absent",
                  Text " instead, and stores the result of the call in this instance. Returns the result of the call.",
                ],
              ],
              Item [ Paragraph [Text "2"] ],
            ],
          ],
      ]

  test_toitdoc
      client
      """
        /**
        quotes escape characters: '\$', '"', '`'.
        dollar needs to be followed by id: \$5.4 \$, 5\$
        strings, too: "'", "\$", "`", "```"
        multiline code: `foo
          bar`
        multiline string: "foo
          bar"
        code with escape: `foo \\` \\\\bar`
        string with escape: "foo\\" bar"
        */
      """
      Contents [
        Section null
          [
            Paragraph [
              Text "quotes escape characters: '\$', '\"', '`'."
            ],
            Paragraph [
              Text "dollar needs to be followed by id: \$5.4 \$, 5\$"
            ],
            Paragraph [
              Text """strings, too: "'", "\$", "`", "```\""""
            ],
            Paragraph [
              Text "multiline code: ",
              Code "foo bar"
            ],
            Paragraph [
              Text """multiline string: "foo bar\""""
            ],
            Paragraph [
              Text "code with escape: ",
              Code "foo ` \\bar"
            ],
            Paragraph [
              Text """string with escape: "foo\\" bar\""""
            ],
          ],
      ]

  test_toitdoc
      client
      """
        /**
        foo/*:  '\$', '"', '`'.*/bar
        /*
        dollar needs to be followed by id: \$5.4 \$, 5\$
        strings, too: "'", "\$", "`", "```"
        */
        /*"`'*/
        /*\\*/still in comment*/
        /*\\\\*/
        done
        */
      """
      Contents [
        Section null
          [
            Paragraph [
              Text "foobar"
            ],
            Paragraph [
              Text "done"
            ],
          ],
      ]
