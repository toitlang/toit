// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Rename test runner that verifies rename correctness by:
1. Copying test files to a temp directory.
2. Sending rename requests at marked positions.
3. Checking that returned edit ranges cover the complete identifier.
4. Verifying that the expected locations match the actual edit locations.

Test markers use a comment block with a caret to indicate the column and
a list of expected location names (matching `@ name` markers):
  some-identifier
  /*
  @ some-def
  ^
    [some-def, some-call]
  */

The `@ name` marker is optional in the block (location-only or test-only
blocks are also supported).

An empty list `[]` means the rename should return null (not renamable).
*/

import .lsp-client show LspClient run-client-test
import expect show *
import host.file
import host.directory
import .utils show *
import fs

parse-location-names line/string -> List:
  open := line.index-of "["
  close := line.index-of "]"
  if open == -1 or close == -1 or close <= open:
    throw "Expected location list like [foo, bar], got: '$line'"
  comma-separated-list := line.copy (open + 1) close
  if comma-separated-list == "": return []
  return comma-separated-list.split ", "

find-test-line-index lines/List marker-index/int -> int:
  test-line-index := marker-index - 1
  while test-line-index > 0:
    candidate := lines[test-line-index].trim
    if candidate == "*/":
      test-line-index--
      while test-line-index > 0 and not lines[test-line-index].trim.starts-with "/*":
        test-line-index--
      test-line-index--
    else if candidate.starts-with "/*":
      test-line-index--
    else:
      break
  return test-line-index

/**
Finds all relative imports in $content (lines starting with `import .`)
  and returns a list of source file paths (absolute) that are imported.
*/
find-relative-imports content/string source-dir/string -> List:
  result := []
  lines := content.split "\n"
  lines.do: |line|
    line = line.trim --right "\r"
    if line.starts-with "import .":
      // Extract the module name from `import .module-name` or
      //   `import .module-name show ...`.
      rest := line["import .".size..]
      if rest.contains " ":
        rest = rest[..rest.index-of " "]
      // Convert dots to path separators for parent-directory imports.
      parts := rest.split "."
      // Build the path relative to source-dir.
      path := "$source-dir/$(parts.join "/").toit"
      result.add path
  return result

/**
Copies the test file and its dependencies to the given $target-dir.
Returns a map from original-path -> target-path.
*/
copy-test-files test-path/string target-dir/string -> Map:
  path-map := {:}
  to-process := [test-path]
  processed := {}

  while not to-process.is-empty:
    current := to-process.last
    to-process.resize (to-process.size - 1)

    if processed.contains current: continue
    processed.add current

    if not file.is-file current: continue

    // Use just the basename for all files (they are all siblings).
    basename := fs.basename current
    target := "$target-dir/$basename"
    file.copy --source=current --target=target
    path-map[current] = target

    // Find imports in this file.
    content := (file.read-contents current).to-string
    current-dir := fs.dirname current
    imports := find-relative-imports content current-dir
    imports.do: to-process.add it

  return path-map

main args:
  test-path := args[0]
  args = args.copy 1

  run-client-test args: test it test-path

test client/LspClient test-path/string -> none:
  locations := extract-locations test-path
  // Copy test files to temp directory.
  temp-dir := directory.mkdtemp "/tmp/lsp_rename_test-"
  try:
    path-map := copy-test-files test-path temp-dir
    temp-test-path := path-map[test-path]

    content := (file.read-contents temp-test-path).to-string

    // Open all files with the LSP.
    client.send-did-open --path=temp-test-path --text=content
    path-map.do: |original-path temp-path|
      if temp-path != temp-test-path:
        dep-content := (file.read-contents temp-path).to-string
        client.send-did-open --path=temp-path --text=dep-content

    // Parse test markers across all files.
    path-map.do: |original-path temp-path|
      file-content := (file.read-contents temp-path).to-string
      lines := (file-content.trim --right "\n").split "\n"
      lines = lines.map --in-place: it.trim --right "\r"

      for i := 0; i < lines.size; i++:
        line := lines[i]
        if line.starts-with "/*" and not line.starts-with "/**":
          // Single-line block (e.g., /*@ name */) — no caret possible, skip.
          if line.trim.ends-with "*/": continue

          // Walk backward past any preceding consecutive marker blocks to
          // find the actual code line.
          test-line-index := find-test-line-index lines i

          // Scan the block for a caret line. Skip any `@ name` lines.
          caret-column := null
          j := i + 1
          while j < lines.size and not lines[j].trim.starts-with "*/":
            block-line := lines[j]
            if block-line.contains "^":
              caret-column = block-line.index-of "^"
            j++
          if caret-column == null:
            // No caret in this block — skip to end of block.
            i = j
            continue
          column := caret-column

          // Collect expected-location lines (everything after the caret,
          // before the closing "*/", excluding "@" lines).
          expected-lines := []
          found-caret := false
          k := i + 1
          while k < lines.size and not lines[k].trim.starts-with "*/":
            if found-caret:
              trimmed := lines[k].trim
              if not trimmed.contains "@":
                expected-lines.add trimmed
            else if lines[k].contains "^":
              found-caret = true
            k++

          // Advance i past the closing "*/".
          i = k

          if expected-lines.is-empty:
            continue

          expected-location-names := parse-location-names expected-lines[0]
          expected-count := expected-location-names.size

          // Build file contents map from the original source files.
          file-contents := {:}
          path-map.do: |orig-p tmp-p|
            file-contents[tmp-p] = (file.read-contents orig-p).to-string

          temp-to-original := {:}
          path-map.do: |orig-p tmp-p|
            temp-to-original[tmp-p] = orig-p

          // Ensure fresh content is sent to LSP.
          file-contents.do: |path fc|
            client.send-did-change --path=path fc

          // Ask prepareRename for the original symbol name, then
          // send the rename request.
          prepare-response := client.send-prepare-rename-request
              --path=temp-path
              test-line-index
              column

          response := client.send-rename-request
              --path=temp-path
              test-line-index
              column
              "new-name"

          if expected-count == 0:
            expect-null response
            continue

          expect-not-null response
          expect-not-null prepare-response
          expected-name := prepare-response["placeholder"]

          changes := response["changes"]
          actual-locations := []
          changes.do: |uri edits|
            path := client.to-path uri
            source-path := temp-to-original[path]
            fc := file-contents.get path
            fc-lines := fc ? (fc.split "\n") : null
            edits.do: |edit|
              expect-equals "new-name" edit["newText"]
              start := edit["range"]["start"]
              end := edit["range"]["end"]
              start-line := start["line"]
              start-char := start["character"]
              end-line := end["line"]
              end-char := end["character"]
              // Verify the edited range covers the original name.
              if fc-lines:
                if start-line == end-line:
                  old-text := fc-lines[start-line][start-char..end-char]
                  // In Toit, underscores and hyphens are interchangeable
                  //   in identifiers. Normalize before comparing.
                  normalized := old-text.replace --all "_" "-"
                  if normalized != expected-name:
                    print "ERROR: Edit at line $(start-line+1) covers '$old-text', expected '$expected-name'"
                  expect-equals expected-name normalized
              if source-path:
                actual-locations.add (Location source-path start-line start-char)

          expected-locations := expected-location-names.map: |name|
            location := locations.get name
            if not location:
              throw "Unknown expected location '$name'"
            location
          if expected-locations.size != actual-locations.size:
            print "ERROR: Expected locations $expected-locations but got $actual-locations"
          expect-equals expected-locations.size actual-locations.size
          expected-locations.do:
            if not actual-locations.contains it:
              print "ERROR: Missing expected location $it in $actual-locations"
            expect (actual-locations.contains it)

  finally:
    directory.rmdir --recursive temp-dir
