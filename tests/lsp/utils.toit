// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file
import bytes
import host.pipe
import reader show BufferedReader

combine_and_replace lines replacement_index replacement_line:
  builder := bytes.Buffer
  for i := 0; i < lines.size; i++:
    if i == replacement_index:
      builder.write replacement_line
    else:
      builder.write lines[i]
    builder.put_byte '\n'
  return builder.bytes.to_string

class Location:
  path / string ::= ""
  line / int ::= -1
  column / int ::= -1

  constructor .path .line .column:

  operator== other/Location:
    return path == other.path and line == other.line and column == other.column

  stringify -> string:
    return "$path:$line:$column"

// Also imports all relatively imported files.
// Fails if there is an indirect recursion (directly importing itself is ok).
extract_locations path -> Map/*<string, Location>*/:
  content := (file.read_content path).to_string
  lines := (content.trim --right "\n").split "\n"
  result := {:}
  for i := 0; i < lines.size; i++:
    line := lines[i]
    if line.starts_with "import ." or line.starts_with "// import_for_locations .":
      first_dot := line.index_of "."
      imported_id := line.copy first_dot + 1
      if imported_id.contains " ":
        imported_id = imported_id.copy 0 (imported_id.index_of " ")
      dir := path.copy 0 (path.index_of --last "/")
      while imported_id.starts_with ".":
        dir = dir.copy 0 (dir.index_of --last "/")
        imported_id = imported_id.copy 1
      imported_id = imported_id.replace --all "." "/"
      imported_path := "$dir/$(imported_id).toit"
      if imported_path != path:
        imported_locations := extract_locations imported_path
        imported_locations.do: |key value|
          assert: not result.contains key or result[key] == value
          result[key] = value

    if line.starts_with "/*":
      definition_line := i - 1
      if not line.contains "@":
        // This should only happen if we want to have a test/location at the
        // beginning of the line. (Or if this is the data for a test).
        i++
        line = lines[i]
      if not line.contains "@": continue

      if line.ends_with "*/": line = line.trim --right "*/"
      line = line.trim
      column := line.index_of "@"

      name := line.copy (column + 2)
      assert: not result.contains name
      result[name] = Location path definition_line column
  return result

run_toit toitc args -> List?:
  cpp_pipes := pipe.fork
      true                // use_path
      pipe.PIPE_CREATED   // stdin
      pipe.PIPE_CREATED   // stdout
      pipe.PIPE_INHERITED // stderr
      toitc
      [toitc] + args
  cpp_to   := cpp_pipes[0]
  cpp_from := cpp_pipes[1]
  cpp_pid  := cpp_pipes[3]
  try:
    cpp_to.close

    lines := []
    try:
      reader := BufferedReader cpp_from
      while line := reader.read_line:
        lines.add line
    finally:
      cpp_from.close
    return lines
  finally:
    exit_value := pipe.wait_for cpp_pid
    exit_code := pipe.exit_code exit_value
    exit_signal := pipe.exit_signal exit_value
    if exit_signal:
      throw "$toitc exited with signal $exit_signal"
    if exit_code != 0:
      throw "$toitc exited with code $exit_code"
