// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import ...tools.lsp.server.summary
import ...tools.lsp.server.toitdoc-node
import .utils

import host.directory
import expect show *

main args:
  // We are reaching into the server, so we must not spawn the server as
  // a process.
  run-client-test args --no-spawn-process: test it
  // Since we used '--no-spawn-process' we must exit 0.
  exit 0

FILE-URI ::= "untitled:/non_existent.toit"

global-thunk name/string -> ToitdocRef:
  return ToitdocRef
      --text=name
      --kind=ToitdocRef.GLOBAL-METHOD
      --module-uri=FILE-URI
      --holder=null
      --name=name
      --shape=Shape
          --arity=0
          --total-block-count=0
          --named-block-count=0
          --is-setter=false
          --names=[]

expect-statement-equal expected/Statement actual/Statement:
  if expected is CodeSection:
    expect actual is CodeSection
    expect-equals
        (expected as CodeSection).text
        (actual as CodeSection).text
  else if expected is Itemized:
    expect actual is Itemized
    expected-items := (expected as Itemized).items
    actual-items := (actual as Itemized).items
    expect-equals expected-items.size actual-items.size
    expected-items.size.repeat:
      expected-statements := expected-items[it].statements
      actual-statements := actual-items[it].statements
      expect-equals expected-statements.size actual-statements.size
      expected-statements.size.repeat:
        expect-statement-equal expected-statements[it] actual-statements[it]
  else:
    expect expected is Paragraph
    expect actual is Paragraph
    expected-expressions := (expected as Paragraph).expressions
    actual-expressions := (actual as Paragraph).expressions
    expect-equals expected-expressions.size actual-expressions.size
    expected-expressions.size.repeat:
      expected-expression := expected-expressions[it]
      actual-expression := actual-expressions[it]
      if expected-expression is Text:
        expect actual-expression is Text
        expect-equals expected-expression.text actual-expression.text
      else if expected-expression is Code:
        expect actual-expression is Code
        expect-equals expected-expression.text actual-expression.text
      else if expected-expression is Link:
        expect actual-expression is Link
        expect-equals expected-expression.text actual-expression.text
        expect-equals expected-expression.url actual-expression.url
      else if expected-expression is ToitdocRef:
        expect actual-expression is ToitdocRef
        expect-equals expected-expression.text actual-expression.text
        expect-equals expected-expression.kind actual-expression.kind
        expect-equals expected-expression.module-uri actual-expression.module-uri
        expect-equals expected-expression.holder actual-expression.holder
        expect-equals expected-expression.name actual-expression.name
        if expected-expression.shape:
          expected-shape := expected-expression.shape
          actual-shape := actual-expression.shape
          expect-equals expected-shape.arity actual-shape.arity
          expect-equals expected-shape.total-block-count actual-shape.total-block-count
          expect-equals expected-shape.named-block-count actual-shape.named-block-count
          expect-equals expected-shape.is-setter actual-shape.is-setter
          expect-list-equals expected-shape.names actual-shape.names
        else:
          expect-null actual-expression.shape
      else:
        unreachable


test-toitdoc client/LspClient str/string expected / Contents:
  client.send-did-change --uri=FILE-URI str
  (client.diagnostics-for --uri=FILE-URI).do: print it
  expect (client.diagnostics-for --uri=FILE-URI).is-empty
  project-uri := client.server.documents_.project-uri-for --uri=FILE-URI
  // Reaching into the private state of the server.
  analyzed-documents := client.server.documents_.analyzed-documents-for --project-uri=project-uri
  document := analyzed-documents.get-existing --uri=FILE-URI
  summary := document.summary
  actual := summary.toitdoc
  expect-equals expected.sections.size actual.sections.size
  actual.sections.size.repeat:
    expected-section := expected.sections[it]
    actual-section := actual.sections[it]
    expect-equals expected-section.title actual-section.title
    expect-equals expected-section.statements.size actual-section.statements.size
    expected-section.statements.size.repeat:
      expected-statement := expected-section.statements[it]
      actual-statement := actual-section.statements[it]
      expect-statement-equal expected-statement actual-statement

test client/LspClient:
  client.send-did-open --uri=FILE-URI --text=""

  test-toitdoc
      client
      """
      /**
      Simple
      */
      """
      Contents [
        Section null 1
          [
            Paragraph [
              Text "Simple"
            ]
          ]
      ]

  test-toitdoc
      client
      """
      /**
      Simple
        multiline
      */
      """
      Contents [
        Section null 1
          [
            Paragraph [
              Text "Simple multiline"
            ]
          ]
      ]

  test-toitdoc
      client
      """
        /**
        Indented
        */
      """
      Contents [
        Section null 1
          [
            Paragraph [
              Text "Indented"
            ]
          ]
      ]

  test-toitdoc
      client
      """
        /**
        Indented
          multiline
        */
      """
      Contents [
        Section null 1
          [
            Paragraph [
              Text "Indented multiline"
            ]
          ]
      ]

  test-toitdoc
      client
      """
        /**
        Indented \$ref \$(ref)
        */

        ref:
      """
      Contents [
        Section null 1
          [
            Paragraph [
              Text "Indented ",
              global-thunk "ref",
              Text " ",
              global-thunk "ref",
            ]
          ]
      ]

  test-toitdoc
      client
      """
        /**
        Indented `code`
        */
      """
      Contents [
        Section null 1
          [
            Paragraph [
              Text "Indented ",
              Code "code",
            ]
          ]
      ]

  test-toitdoc
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
        Section null 1
          [
            Paragraph [ Text "Indented" ],
            CodeSection "\nCode section\n",
            Paragraph [ Text "another paragraph" ],
          ]
      ]

  test-toitdoc
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
        Section "Section1" 1
          [
            Paragraph [ Text "Indented" ],
            CodeSection "\nCode section\n",
            Paragraph [ Text "another paragraph" ],
          ]
      ]

  test-toitdoc
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
        Section null 1
          [
            Paragraph [ Text "unnamed section" ],
          ],
        Section "Section1" 1
          [
            Paragraph [ Text "Indented" ],
            CodeSection "\nCode section\n",
            Paragraph [ Text "another paragraph" ],
          ]
      ]

  test-toitdoc
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
        Section null 1
          [
            Paragraph [
              Text "unnamed section ",
              Code "code",
              Text " and ",
              global-thunk "ref",
              Text " and ",
              global-thunk "ref",
              Text " followed by an indentation",
            ],
          ],
        Section "Section1" 1
          [
            Paragraph [ Text "Indented" ],
            CodeSection "\nCode section\n",
            Paragraph [ Text "another paragraph" ],
          ]
      ]

  test-toitdoc
      client
      """
        /**
        A

        B
          C
        */
      """
      Contents [
        Section null 1
          [
            Paragraph [
              Text "A",
            ],
            Paragraph [
              Text "B C",
            ],
          ],
      ]

  test-toitdoc
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
        Section null 1
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

  test-toitdoc
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
        Section null 1
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

  test-toitdoc
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
        Section null 1
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

  test-toitdoc
      client
      """
        /**
        Updates the value of the given \$key.

        If this instance contains the \$key, calls the \$updater with the current value,
          and replaces the old value with the result. Returns the result of the call.

        If this instance does not contain the \$key, calls \$if-absent instead, and
          stores the result of the call in this instance. Returns the result of the call.
        */

      key:
      updater:
      if-absent:
      """
      Contents [
        Section null 1
          [
            Paragraph [
              Text "Updates the value of the given ",
              global-thunk "key",
              Text ".",
            ],
            Paragraph [
              Text "If this instance contains the ",
              global-thunk "key",
              Text ", calls the ",
              global-thunk "updater",
              Text " with the current value, and replaces the old value with the result. Returns the result of the call.",
            ],
            Paragraph [
              Text "If this instance does not contain the ",
              global-thunk "key",
              Text ", calls ",
              global-thunk "if-absent",
              Text " instead, and stores the result of the call in this instance. Returns the result of the call.",
            ],
          ],
      ]

  test-toitdoc
      client
      """
        /**
        - Updates the value of the given \$key.

          If this instance contains the \$key, calls the \$updater with the current value,
            and replaces the old value with the result. Returns the result of the call.

          If this instance does not contain the \$key, calls \$if-absent instead, and
            stores the result of the call in this instance. Returns the result of the call.
        - 2
        */

      key:
      updater:
      if-absent:
      """
      Contents [
        Section null 1
          [
            Itemized [
              Item [
                Paragraph [
                  Text "Updates the value of the given ",
                  global-thunk "key",
                  Text ".",
                ],
                Paragraph [
                  Text "If this instance contains the ",
                  global-thunk "key",
                  Text ", calls the ",
                  global-thunk "updater",
                  Text " with the current value, and replaces the old value with the result. Returns the result of the call.",
                ],
                Paragraph [
                  Text "If this instance does not contain the ",
                  global-thunk "key",
                  Text ", calls ",
                  global-thunk "if-absent",
                  Text " instead, and stores the result of the call in this instance. Returns the result of the call.",
                ],
              ],
              Item [ Paragraph [Text "2"] ],
            ],
          ],
      ]

  test-toitdoc
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
        Section null 1
          [
            Paragraph [
              Text "quotes escape characters: '\$', '\"', '`'."
            ],
            Paragraph [
              Text "dollar needs to be followed by id: \$5.4 \$, 5\$"
            ],
            Paragraph [
              Text """strings, too: "'", "\$", "`", "```""""
            ],
            Paragraph [
              Text "multiline code: ",
              Code "foo bar"
            ],
            Paragraph [
              Text """multiline string: "foo bar""""
            ],
            Paragraph [
              Text "code with escape: ",
              Code "foo ` \\bar"
            ],
            Paragraph [
              Text """string with escape: "foo" bar""""
            ],
          ],
      ]

  test-toitdoc
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
        Section null 1
          [
            Paragraph [
              Text "foobar"
            ],
            Paragraph [
              Text "done"
            ],
          ],
      ]

  test-toitdoc
      client
      """
        /**
        https://example.com

        - http://example.com
        */
      """
      Contents [
        Section null 1
          [
            Paragraph [
              Link "https://example.com" "https://example.com"
            ],
            Itemized [
              Item [
                Paragraph [
                  Link "http://example.com" "http://example.com"
                ]
              ],
            ],
          ],
      ]

  test-toitdoc
      client
      """
      /**
      - \\\$foo
      - `\$`
      - `\\``
      - \\`
      - `\\``
      \\
      "\\\\\\\\.\\\\"
      \\[foo]
      */
      """
      Contents [
        Section null 1
          [
            Itemized [
              Item [
                Paragraph [
                  Text "\$foo"
                ]
              ],
              Item [
                Paragraph [
                  Code "\$"
                ]
              ],
              Item [
                Paragraph [
                  Code "`"
                ]
              ],
              Item [
                Paragraph [
                  Text "`"
                ]
              ],
              Item [
                Paragraph [
                  Code "`"
                ]
              ],
            ],
            Paragraph [
              Text "\\"
            ],
            Paragraph [
              Text """"\\\\.\\""""
            ],
            Paragraph [
              Text "[foo]"
            ],
          ],
      ]


  test-toitdoc
      client
      """
      /**
      # 1
      ## 2
      ### 3
      */
      """
      Contents [
        Section "1" 1 [],
        Section "2" 2 [],
        Section "3" 3 [],
      ]
