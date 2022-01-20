// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import host.directory
import expect show *
import host.file
import monitor

is_whitespace c -> bool:
  return c == ' ' or c == '\n'

is_special c -> bool:
  return c == '"' or c == '\n' or c == '.' or c == ' ' or c == ':' or c == '-' or
      c == '$' or c == '[' or c == ']' or c == '(' or c == ')'

SHARD_COUNT ::= 8

main arguments:
  files_to_check := null
  if arguments.size > 4:
    files_to_check = arguments.copy 4
    arguments = arguments.copy 0 4
  else:
    files_to_check = ["$(directory.cwd)/protocol1.toit"]

  // We split the files into SHARD_COUNT chunks.
  // Each chunk has a length of at least `chunk_size`.
  // When `files_to_check` can't be evenly divided by SHARD_COUNT, the rest
  // is distributed to the first `rest` shards. That is, the first `rest`
  // chunks, are of size `chunk_size + 1`.
  chunk_size := files_to_check.size / SHARD_COUNT
  rest := files_to_check.size % SHARD_COUNT
  total_errors := 0
  semaphore := monitor.Semaphore
  spawned_count := 0
  i := 0
  while i < files_to_check.size:
    this_chunk_size := spawned_count < rest ? chunk_size + 1 : chunk_size
    start := i
    end := i + this_chunk_size
    chunk := files_to_check.copy start end
    i = end
    spawned_count++
    task::
      run_client_test
          arguments:
        total_errors += test it chunk
        semaphore.up

  spawned_count.repeat: semaphore.down
  expect_equals 0 total_errors
  print "all done"

test client/LspClient files_to_check/List:
  crash_count := 0  // Just counts all the crashes in the loop. We should have 0 at the end.
  files_to_check.do: |path|
    print "checking $path"

    // Reset the limiter, so we can have a crash-report per file.
    client.send_reset_crash_rate_limit

    client.install_handler "window/showMessage"::
      // We don't expect any crashes, so no need to delete the repros.
      print "crash detected in $path"
      message := it["message"]
      print "Message: $message"
      crash_count++

    content := (file.read_content path).to_string
    client.send_did_open --path=path --text=content

    last_was_whitespace := false
    last_was_special := false
    for i := 0; i < content.size; i++:
      c := content[i]
      c_is_whitespace := is_whitespace c
      if last_was_whitespace and c_is_whitespace:
        continue
      if is_special c:
        last_was_special = true
        client.send_did_change --path=path (content.copy 0 i)
      else if last_was_special:
        // Also check right after these special characters.
        last_was_special = false
        client.send_did_change --path=path (content.copy 0 i)

      last_was_whitespace = c_is_whitespace

    client.send_did_close --path=path

  return crash_count
