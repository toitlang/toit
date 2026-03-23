// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Rename test runner that verifies rename correctness by:
1. Copying test files to a temp directory.
2. Sending rename requests at marked positions.
3. Applying all returned edits.
4. Re-analyzing the modified files to check they still compile.

Test markers use the same format as prepare-rename tests:
  some-identifier
  /*
    ^
    expected-count
  */

The expected-count is the total number of edits across all files.
A count of 0 means the rename should return null (not renamable).
*/

import .lsp-client show LspClient run-client-test
import expect show *
import host.file
import host.directory
import fs

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

/**
Applies text edits from a rename response to in-memory content strings.

The $response is the LSP rename response (a WorkspaceEdit).
The $client is used to convert URIs to paths.
The $file-contents is a map from file-path -> current content string.
*/
apply-rename-edits response/Map client/LspClient file-contents/Map -> none:
  changes := response["changes"]
  changes.do: |uri edits|
    path := client.to-path uri
    content := file-contents.get path
    if not content:
      // The file might not be in our map (e.g. SDK files).
      // Skip it.
      continue.do
    lines := content.split "\n"

    // Sort edits in reverse order (bottom-to-top, right-to-left) to avoid
    //   offset shifting.
    sorted := edits.sort: |a b|
      a-start := a["range"]["start"]
      b-start := b["range"]["start"]
      if a-start["line"] != b-start["line"]:
        b-start["line"] - a-start["line"]
      else:
        b-start["character"] - a-start["character"]

    sorted.do: |edit|
      new-text := edit["newText"]
      start := edit["range"]["start"]
      end := edit["range"]["end"]
      start-line := start["line"]
      start-char := start["character"]
      end-line := end["line"]
      end-char := end["character"]

      if start-line == end-line:
        line := lines[start-line]
        lines[start-line] = line[..start-char] + new-text + line[end-char..]
      else:
        // Multi-line edit (unlikely for rename, but handle it).
        first := lines[start-line][..start-char] + new-text
        last := lines[end-line][end-char..]
        new-lines := [first + last]
        for j := end-line; j >= start-line; j--:
          lines.remove --at=j
        lines.insert --at=start-line new-lines[0]

    file-contents[path] = lines.join "\n"

main args:
  test-path := args[0]
  args = args.copy 1

  run-client-test args: test it test-path

test client/LspClient test-path/string:
  // Step 1: Copy test files to temp directory.
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

    // Step 2: Parse test markers across all files.
    path-map.do: |original-path temp-path|
      file-content := (file.read-contents temp-path).to-string
      lines := (file-content.trim --right "\n").split "\n"
      lines = lines.map --in-place: it.trim --right "\r"

      for i := 0; i < lines.size; i++:
        line := lines[i]
        if line.starts-with "/*" and not line.starts-with "/**":
          // Walk backward past any preceding consecutive marker blocks to
          // find the actual code line.  When multiple markers annotate the
          // same source line, only the first block's "i - 1" points to the
          // code line; subsequent blocks would point to a closing "*/".
          test-line-index := i - 1
          while test-line-index > 0 and lines[test-line-index].trim == "*/":
            test-line-index--
            while test-line-index > 0 and not (lines[test-line-index].starts-with "/*"):
              test-line-index--
            // Now at the opening "/*" of the earlier block; step before it.
            test-line-index--
          if i + 1 >= lines.size: continue
          next-line := lines[i + 1]
          if not next-line.contains "^": continue
          column := next-line.index-of "^"
          // Skip past the caret line.
          i += 2
          // Read the expected reference count.
          if i >= lines.size: continue
          count-line := lines[i].trim
          if count-line == "*/":
            continue
          expected-count := int.parse count-line
          i++
          while i < lines.size and not lines[i].starts-with "*/":
            i++

          // Step 3: Build fresh file contents map from the temp copies.
          file-contents := {:}
          path-map.do: |orig-p tmp-p|
            file-contents[tmp-p] = (file.read-contents orig-p).to-string

          // Ensure fresh content is sent to LSP.
          file-contents.do: |path fc|
            client.send-did-change --path=path fc

          // Step 4: Ask prepareRename for the original symbol name, then
          //   send the rename request.
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
          total-edits := 0
          changes.do: |uri edits|
            path := client.to-path uri
            fc := file-contents.get path
            fc-lines := fc ? (fc.split "\n") : null
            edits.do: |edit|
              expect-equals "new-name" edit["newText"]
              // Verify the edited range covers the original name.
              if fc-lines:
                start := edit["range"]["start"]
                end := edit["range"]["end"]
                start-line := start["line"]
                start-char := start["character"]
                end-line := end["line"]
                end-char := end["character"]
                if start-line == end-line:
                  old-text := fc-lines[start-line][start-char..end-char]
                  // In Toit, underscores and hyphens are interchangeable
                  //   in identifiers. Normalize before comparing.
                  normalized := old-text.replace --all "_" "-"
                  if normalized != expected-name:
                    print "ERROR: Edit at line $(start-line+1) covers '$old-text', expected '$expected-name'"
                  expect-equals expected-name normalized
              total-edits++
          expect-equals expected-count total-edits

          // Step 5: Apply all edits to in-memory file contents.
          apply-rename-edits response client file-contents

          // Step 6: Write updated files to disk and send to LSP.
          file-contents.do: |path new-content|
            file.write-contents --path=path new-content
            client.send-did-change --path=path new-content

          // Step 7: Re-open the main file to trigger re-analysis and
          //   check for diagnostics.
          client.send-did-open
              --path=temp-test-path
              --text=file-contents[temp-test-path]

          diagnostics := client.diagnostics-for --path=temp-test-path
          if diagnostics:
            error-diagnostics := diagnostics.filter:
              it["severity"] == 1  // 1 = Error in LSP.
            if not error-diagnostics.is-empty:
              print "ERROR: Rename at line $(test-line-index + 1), column $column produced errors after applying edits:"
              error-diagnostics.do: |diag|
                print "  $(diag["message"])"
              expect error-diagnostics.is-empty

  finally:
    directory.rmdir --recursive temp-dir
