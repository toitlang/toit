// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Selection-range test runner.

Test files use `/* */` comment blocks below each code line under test.
Inside a block:

- `@name` defines a named anchor at the column of `@` on the code line
    above the block. Anchors record both line and column.
- `^` marks the cursor column (on the code line above) where the
    selection-range request is sent.
- `[ ]` lines specify expected ranges (innermost first). The positions
    of the brackets and/or anchor names determine the range endpoints:
    - `[   ]`            start and end from bracket columns on the code line.
    - `[start-id end-id]` start and end from the named anchors.
    - `[ end-id]`        start from `[` column on the code line,
                           end from the named anchor.
    - `[start-id ]`      start from the named anchor,
                           end from `]` column on the code line.
*/

import .lsp-client show LspClient run-client-test
import expect show *
import host.file

/**
A line/column position (both 0-indexed).
*/
class Position:
  line / int ::= -1
  column / int ::= -1
  constructor .line .column:
  stringify -> string: return "$line:$column"

/**
Walks backward from $marker-index past any preceding consecutive
  `/* */` blocks to find the actual code line.
*/
find-code-line-index lines/List marker-index/int -> int:
  index := marker-index - 1
  while index > 0:
    candidate := lines[index].trim
    if candidate == "*/":
      index--
      while index > 0 and not lines[index].trim.starts-with "/*":
        index--
      index--
    else if candidate.starts-with "/*":
      index--
    else:
      break
  return index

/**
Parses a bracket range line like `[   ]` or `[id1 id2]`.

Returns a two-element list [start-position, end-position] where each
  position is a $Position.

The $code-line-index is the 0-indexed line of the code under test
  (used when a bracket endpoint is positional rather than a named anchor).
*/
parse-range-spec range-line/string code-line-index/int anchors/Map -> List:
  open := range-line.index-of "["
  close := range-line.index-of "]"
  if open == -1 or close == -1:
    throw "Expected bracket range like [  ] or [id1 id2], got: '$range-line'"

  inner := range-line[open + 1 .. close]
  tokens := (inner.trim).split " "
  // Remove empty strings that result from multiple spaces.
  tokens = tokens.filter: it != ""

  start-pos / Position := ?
  end-pos / Position := ?

  if tokens.size == 0:
    // `[   ]` — both endpoints from bracket positions on the code line.
    start-pos = Position code-line-index open
    end-pos = Position code-line-index close
  else if tokens.size == 2:
    // `[start-id end-id]` — both endpoints from named anchors.
    start-pos = lookup-anchor_ anchors tokens[0]
    end-pos = lookup-anchor_ anchors tokens[1]
  else if tokens.size == 1:
    token := tokens[0]
    // Determine whether the token is the start or end anchor based on
    // adjacent whitespace: if there is a space right after `[`, the
    // start is positional and the token is the end anchor (e.g., `[ end-id]`).
    // Otherwise the token is the start anchor (e.g., `[start-id ]`).
    has-leading-space := inner.size > 0 and inner[0] == ' '
    if has-leading-space:
      start-pos = Position code-line-index open
      end-pos = lookup-anchor_ anchors token
    else:
      start-pos = lookup-anchor_ anchors token
      end-pos = Position code-line-index close
  else:
    throw "Expected 0, 1, or 2 anchor names in bracket range, got $(tokens.size): '$range-line'"

  return [start-pos, end-pos]

lookup-anchor_ anchors/Map name/string -> Position:
  result := anchors.get name
  if not result: throw "Unknown anchor '$name'"
  return result

main args:
  test-path := args[0]
  args = args.copy 1

  run-client-test args: test it test-path

test client/LspClient test-path/string:
  content := (file.read-contents test-path).to-string
  client.send-did-open --path=test-path --text=content

  lines := (content.trim --right "\n").split "\n"
  lines = lines.map --in-place: it.trim --right "\r"

  // First pass: collect all anchors.
  anchors := {:}  // Map<string, Position>
  for i := 0; i < lines.size; i++:
    line := lines[i]
    if line.starts-with "/*" and not line.starts-with "/**":
      if line.trim.ends-with "*/":
        // Single-line block — check for anchor.
        if line.contains "@":
          code-line-index := find-code-line-index lines i
          at-col := line.index-of "@"
          name := line[at-col + 1 ..].trim
          if name.ends-with "*/": name = name.trim --right "*/"
          name = name.trim
          anchors[name] = Position code-line-index at-col
        continue
      // Multi-line block — scan for `@` lines.
      code-line-index := find-code-line-index lines i
      j := i + 1
      while j < lines.size and not lines[j].trim.starts-with "*/":
        block-line := lines[j]
        if block-line.contains "@":
          at-col := block-line.index-of "@"
          name := block-line[at-col + 1 ..].trim
          anchors[name] = Position code-line-index at-col
        j++

  // Second pass: find test blocks (those with a `^` caret) and run tests.
  for i := 0; i < lines.size; i++:
    line := lines[i]
    if not (line.starts-with "/*" and not line.starts-with "/**"): continue
    if line.trim.ends-with "*/": continue  // Single-line block — skip.

    code-line-index := find-code-line-index lines i

    // Scan block for a caret and bracket range lines.
    caret-column := null
    range-lines := []
    j := i + 1
    while j < lines.size and not lines[j].trim.starts-with "*/":
      block-line := lines[j]
      if block-line.contains "^":
        caret-column = block-line.index-of "^"
      else if block-line.contains "[" and block-line.contains "]" and not block-line.contains "@":
        range-lines.add block-line
      j++
    // Advance i past the closing "*/".
    i = j

    if caret-column == null: continue
    if range-lines.is-empty: continue

    // Parse expected ranges.
    expected-ranges := range-lines.map:
      parse-range-spec it code-line-index anchors

    // Send the selection-range request.
    client.send-did-change --path=test-path content
    positions := [{"line": code-line-index, "character": caret-column}]
    response := client.send-selection-range-request --path=test-path positions
    expect-not-null response
    expect-equals 1 response.size

    // Walk the selection-range chain and compare against expected ranges.
    selection-range := response[0]
    expected-ranges.do: | expected/List |
      expected-start := expected[0] as Position
      expected-end := expected[1] as Position
      expect (selection-range != null)
          --message="Expected range $(expected-start)-$(expected-end) but chain ended"
      range := selection-range["range"]
      start := range["start"]
      end := range["end"]
      actual-str := "$(start["line"]):$(start["character"])-$(end["line"]):$(end["character"])"
      expected-str := "$(expected-start)-$(expected-end)"
      expect (start["line"] == expected-start.line
          and start["character"] == expected-start.column
          and end["line"] == expected-end.line
          and end["character"] == expected-end.column)
          --message="Expected range $expected-str but got $actual-str"
      selection-range = selection-range.get "parent"
