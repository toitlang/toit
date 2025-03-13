// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import host.directory
import expect show *
import host.file
import monitor

is-whitespace c -> bool:
  return c == ' ' or c == '\n'

is-special c -> bool:
  return c == '"' or c == '\n' or c == '.' or c == ' ' or c == ':' or c == '-' or
      c == '$' or c == '[' or c == ']' or c == '(' or c == ')'

SHARD-COUNT ::= 8

main arguments:
  files-to-check := null
  if arguments.size > 4:
    files-to-check = arguments.copy 4
    arguments = arguments.copy 0 4
  else:
    files-to-check = ["$(directory.cwd)/protocol1.toit"]

  // We split the files into SHARD_COUNT chunks.
  // Each chunk has a length of at least `chunk_size`.
  // When `files_to_check` can't be evenly divided by SHARD_COUNT, the rest
  // is distributed to the first `rest` shards. That is, the first `rest`
  // chunks, are of size `chunk_size + 1`.
  chunk-size := files-to-check.size / SHARD-COUNT
  rest := files-to-check.size % SHARD-COUNT
  total-errors := 0
  semaphore := monitor.Semaphore
  spawned-count := 0
  i := 0
  while i < files-to-check.size:
    this-chunk-size := spawned-count < rest ? chunk-size + 1 : chunk-size
    start := i
    end := i + this-chunk-size
    chunk := files-to-check.copy start end
    i = end
    spawned-count++
    task::
      run-client-test
          arguments:
        total-errors += test it chunk
        semaphore.up

  spawned-count.repeat: semaphore.down
  expect-equals 0 total-errors
  print "all done"

test client/LspClient files-to-check/List:
  crash-count := 0  // Just counts all the crashes in the loop. We should have 0 at the end.
  files-to-check.do: |path|
    print "checking $path"

    // Reset the limiter, so we can have a crash-report per file.
    client.send-reset-crash-rate-limit

    client.install-handler "window/showMessage"::
      // We don't expect any crashes, so no need to delete the repros.
      print "crash detected in $path"
      message := it["message"]
      print "Message: $message"
      crash-count++

    content := (file.read-contents path).to-string
    client.send-did-open --path=path --text=content

    last-was-whitespace := false
    last-was-special := false
    for i := 0; i < content.size; i++:
      c := content[i]
      c-is-whitespace := is-whitespace c
      if last-was-whitespace and c-is-whitespace:
        continue
      if is-special c:
        last-was-special = true
        client.send-did-change --path=path (content.copy 0 i)
      else if last-was-special:
        // Also check right after these special characters.
        last-was-special = false
        client.send-did-change --path=path (content.copy 0 i)

      last-was-whitespace = c-is-whitespace

    client.send-did-close --path=path

  return crash-count
