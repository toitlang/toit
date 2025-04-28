// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import expect show *
import system

main args:
  2.repeat:
    supports-default-range := it == 1
    // TODO(florian): Default range feature is disabled until we can test it on
    // a real editor.
    if supports-default-range: continue.repeat
    pre-initialize := : | _ initialize-param/Map |
      if supports-default-range:
        capabilities := initialize-param.get "capabilities" --init=: {:}
        text-document := capabilities.get "textDocument" --init=: {:}
        completion := text-document.get "completion" --init=: {:}
        completion-list := completion.get "completionList" --init=: {:}
        item-defaults := completion-list.get "itemDefaults" --init=: []
        item-defaults.add "editRange"
    run-client-test args --pre-initialize=pre-initialize:
      test it --supports-default-range=supports-default-range

test client/LspClient --supports-default-range/bool:
  // The path doesn't really need to be non-existing, as we provide content for it
  // anyways.
  DRIVE ::= system.platform == system.PLATFORM-WINDOWS ? "c:" : ""
  DIR ::= "$DRIVE/non_existing_dir_toit_test"
  path := "$DIR/file.toit"

  client.send-did-open --path=path --text="""
    main:
      foo-bar := 499
      foo-bar2 := 42
      foo-
    """

  LINE ::= 3
  PREFIX-START ::= 2
  PREFIX-END ::= 6

  // A completion at the end of the file.
  // Due to the trailing '-' the server sends us a text-range.
  // If a default-range is supported, the completion-request is a CompletionList
  // with a default-range. Otherwise, each completion-item has a text-edit.
  completions := client.send-completion-request --path=path LINE PREFIX-END
  print completions

  if supports-default-range:
    // We got a CompletionList back.
    expect (completions is Map)
    items := completions["items"]
    expect-equals 2 items.size
    items.do: | item |
      expect ("foo-bar" == item["label"] or "foo-bar2" == item["label"])
      expect-not (item.contains "textEdit")
    defaults := completions["itemDefaults"]
    range := defaults["editRange"]
    expect-equals LINE range["start"]["line"]
    expect-equals PREFIX-START range["start"]["character"]
    expect-equals LINE range["end"]["line"]
    expect-equals PREFIX-END range["end"]["character"]
  else:
    expect-equals 2 completions.size
    completions.do: | item |
      expect ("foo-bar" == item["label"] or "foo-bar2" == item["label"])
      text-edit := item["textEdit"]
      expect ("foo-bar" == text-edit["newText"] or "foo-bar2" == text-edit["newText"])
      expect-equals LINE text-edit["range"]["start"]["line"]
      expect-equals PREFIX-START text-edit["range"]["start"]["character"]
      expect-equals LINE text-edit["range"]["end"]["line"]
      expect-equals PREFIX-END text-edit["range"]["end"]["character"]

  // A completion one character before. Since the prefix doesn't
  // end with "-", no text-edit is provided.
  completions = client.send-completion-request --path=path LINE (PREFIX-END - 1)
  expect-equals 2 completions.size
  completions.do: | item |
    expect ("foo-bar" == item["label"] or "foo-bar2" == item["label"])
    expect-not (item.contains "textEdit")
