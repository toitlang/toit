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

    if line.starts-with "/*":
      definition-line := i - 1
      if not line.contains "@":
        // This should only happen if we want to have a test/location at the
        // beginning of the line. (Or if this is the data for a test).
        i++
        line = lines[i]
      if not line.contains "@": continue

      if line.ends-with "*/": line = line.trim --right "*/"
      line = line.trim
      column := line.index-of "@"

      name := line.copy (column + 2)
      assert: not result.contains name
      result[name] = Location path definition-line column
  return result

run-toit toitc args -> List?:
  cpp-pipes := pipe.fork
      true                // use_path
      pipe.PIPE-CREATED   // stdin
      pipe.PIPE-CREATED   // stdout
      pipe.PIPE-INHERITED // stderr
      toitc
      [toitc] + args
  cpp-to   := cpp-pipes[0]
  cpp-from := cpp-pipes[1]
  cpp-pid  := cpp-pipes[3]
  try:
    cpp-to.close

    lines := []
    try:
      reader := io.Reader.adapt cpp-from
      while line := reader.read-line:
        lines.add line
    finally:
      cpp-from.close
    return lines
  finally:
    exit-value := pipe.wait-for cpp-pid
    exit-code := pipe.exit-code exit-value
    exit-signal := pipe.exit-signal exit-value
    if exit-signal:
      throw "$toitc exited with signal $exit-signal"
    if exit-code != 0:
      throw "$toitc exited with code $exit-code"
