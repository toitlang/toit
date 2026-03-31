// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file
import host.pipe
import io
import system
import system show platform

combine-and-replace lines replacement-index replacement-line:
  builder := io.Buffer
  for i := 0; i < lines.size; i++:
    if i == replacement-index:
      builder.write replacement-line
    else:
      builder.write lines[i]
    builder.write-byte '\n'
  return builder.bytes.to-string

class Location:
  path / string ::= ""
  line / int ::= -1
  column / int ::= -1

  constructor .path .line .column:

  operator== other/Location:
    return (to-slash_ path) == (to-slash_ other.path) and line == other.line and column == other.column

  stringify -> string:
    return "$path:$line:$column"

  static to-slash_ path/string -> string:
    if platform == system.PLATFORM-WINDOWS:
      return path.replace --all "\\" "/"
    return path

// Also imports all relatively imported files.
// Fails if there is an indirect recursion (directly importing itself is ok).
extract-locations path -> Map/*<string, Location>*/:
  content := (file.read-contents path).to-string
  lines := (content.trim --right "\n").split "\n"
  if platform == system.PLATFORM-WINDOWS:
    lines = lines.map: |line| line.trim --right "\r"
  result := {:}
  for i := 0; i < lines.size; i++:
    line := lines[i]
    if line.starts-with "import ." or line.starts-with "// import_for_locations .":
      first-dot := line.index-of "."
      imported-id := line.copy first-dot + 1
      if imported-id.contains " ":
        imported-id = imported-id.copy 0 (imported-id.index-of " ")
      dir := path.copy 0 (path.index-of --last "/")
      while imported-id.starts-with ".":
        dir = dir.copy 0 (dir.index-of --last "/")
        imported-id = imported-id.copy 1
      imported-id = imported-id.replace --all "." "/"
      imported-path := "$dir/$(imported-id).toit"
      if imported-path != path:
        imported-locations := extract-locations imported-path
        imported-locations.do: |key value|
          assert: not result.contains key or result[key] == value
          result[key] = value

    if line.starts-with "/*" and not line.starts-with "/**":
      // Walk backward past any preceding marker/test-data blocks to find the
      // actual code line.
      definition-line := i - 1
      while definition-line > 0:
        candidate := lines[definition-line].trim
        if candidate == "*/":
          definition-line--
          while definition-line > 0 and not lines[definition-line].trim.starts-with "/*":
            definition-line--
          definition-line--
        else if candidate.starts-with "/*":
          definition-line--
        else:
          break

      // Scan the block (which may be single-line or multi-line) for a line
      // containing "@".
      at-line := null
      if line.contains "@":
        at-line = line
      else:
        // Multi-line block: scan forward through the block for an "@" line.
        j := i + 1
        while j < lines.size:
          block-line := lines[j]
          if block-line.contains "@":
            at-line = block-line
            break
          if block-line.trim.starts-with "*/" or block-line.trim.ends-with "*/":
            break
          j++
        // Advance i past the closing "*/".
        while i < lines.size:
          if lines[i].trim.starts-with "*/" or lines[i].trim.ends-with "*/":
            break
          i++

      if at-line == null: continue

      // Determine the column from the raw line (before trimming).
      // For single-line blocks like `/*@ name */`, the @ column in the
      // original line IS the identifier column.
      // For multi-line blocks, the @ is on its own line with indentation
      // encoding the column.
      if at-line.ends-with "*/": at-line = at-line.trim --right "*/"
      column := at-line.index-of "@"

      name := at-line[column + 2..].trim
      assert: not result.contains name
      result[name] = Location path definition-line column
  return result

run-toit toit args -> List?:
  process := pipe.fork
      --use-path
      --create-stdin
      --create-stdout
      toit
      [toit] + args
  try:
    process.stdin.close
    return process.stdout.in.read-lines
  finally:
    process.stdout.close
    exit-value := process.wait
    exit-code := pipe.exit-code exit-value
    exit-signal := pipe.exit-signal exit-value
    if exit-signal:
      throw "$toit exited with signal $exit-signal"
    if exit-code != 0:
      throw "$toit exited with code $exit-code"
