// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.directory
import expect show *
import host.file
import encoding.json as json
import encoding.base64 as base64
import monitor
import host.pipe
import reader show BufferedReader
import tar show Tar
import writer show Writer

import .lsp-client show LspClient run-client-test
import .utils

import ...tools.lsp.server.compiler
import ...tools.lsp.server.uri-path-translator
import ...tools.lsp.server.documents
import ...tools.lsp.server.file-server
import ...tools.lsp.server.repro
import ...tools.lsp.server.tar-utils

read-all-lines reader/BufferedReader:
  lines := []
  while true:
    line := reader.read-line
    if line == null: return lines
    lines.add line

UNTITLED-TEXT_ ::= """
  foo: return 499
  main: f
  """

HELLO-WORLD-TEXT_ ::= """
  main args: print "hello \$args[0]"
  """

GOOD-BYE-WORLD-TEXT_ ::= """
  main args: print "good bye \$args[0]"
  """

create-compiler-input --path/string:
  line-number := 1
  column-number := 7
  return "COMPLETE\n$path\n$line-number\n$column-number\n"

check-compiler-output reader/BufferedReader:
  suggestions := read-all-lines reader
  expect (suggestions.contains "foo")

/**
Creates a tar archive at the given $path.

Returns a `compiler-input`. When running the repro with that input, it should
  yield a result that checks successfully $check-compiler-output.
*/
create-archive path toitc -> string:
  uri-translator := UriPathTranslator
  documents := Documents uri-translator

  untitled-uri := "untitled:Untitled1"
  untitled-path := uri-translator.to-path untitled-uri

  documents.did-open --uri=untitled-uri UNTITLED-TEXT_ 1
  timeout-ms := -1  // No timeout.

  repro-filesystem := FilesystemLocal (sdk-path-from-compiler toitc)
  protocol := FileServerProtocol documents repro-filesystem uri-translator
  compiler := Compiler toitc uri-translator timeout-ms
      --protocol=protocol
      --project-uri=uri-translator.to-uri directory.cwd

  compiler-input := create-compiler-input --path=untitled-path

  suggestions := null
  compiler.run --compiler-input=compiler-input:
    check-compiler-output it

  write-repro
      --repro-path=path
      --compiler-flags=compiler.build-run-flags
      --compiler-input=compiler-input
      --info="Test"
      --protocol=protocol
      --cwd-path=directory.cwd
      --include-sdk

  print "created $path"

  return compiler-input

/**
Runs the compiler using the repro archive.
*/
test-repro-server archive-path toitc toitlsp compiler-input:
  cpp-pipes := pipe.fork
      true                // use_path
      pipe.PIPE-CREATED   // stdin
      pipe.PIPE-CREATED   // stdout
      pipe.PIPE-INHERITED // stderr
      toitc
      [
        toitc,
        "--lsp",
      ]
  cpp-to   := cpp-pipes[0]
  cpp-from := cpp-pipes[1]
  cpp-pid  := cpp-pipes[3]

  // Start the repro server and extract the port from its output.
  // We use the `--json` flag to make that easier.
  port/int := ?
  toitlsp-pipes := pipe.fork
      true                // use_path
      pipe.PIPE-CREATED   // stdin
      pipe.PIPE-CREATED   // stdout
      pipe.PIPE-INHERITED // stderr
      toitlsp
      [toitlsp, "repro", "serve", "--json", archive-path]
  toitlsp-to := toitlsp-pipes[0]
  toitlsp-from := toitlsp-pipes[1]
  toitlsp-pid := toitlsp-pipes[3]
  r := BufferedReader toitlsp-from
  while true:
    if line := r.read-line:
      result := json.parse line
      port = result["port"]
      toitlsp-from.close
      break

  try:
    writer := Writer cpp-to
    writer.write "$port\n"
    writer.write compiler-input
  finally:
    cpp-to.close

  try:
    check-compiler-output (BufferedReader cpp-from)
  finally:
    cpp-from.close
    exit-value := pipe.wait-for cpp-pid
    expect-equals null
        pipe.exit-signal exit-value
    expect-equals 0
        pipe.exit-code exit-value

  pipe.kill_ toitlsp-pid 9
  pipe.wait-for toitlsp-pid

archive-test
    archive-path/string
    snapshot-path/string
    toitc/string
    toitlsp/string
    client/LspClient:
  uri-translator := UriPathTranslator
  untitled-uri := "untitled:Untitled1"
  untitled-path := uri-translator.to-path untitled-uri

  client.send-did-open --uri=untitled-uri --text=UNTITLED-TEXT_
  tar-string := client.send-request "toit/archive" {"uri": untitled-uri}
  content := base64.decode tar-string
  writer := file.Stream.for-write archive-path
  (Writer writer).write content
  writer.close

  compiler-input := create-compiler-input --path=untitled-path
  test-repro-server archive-path toitc toitlsp compiler-input

  client.send-did-change --uri=untitled-uri HELLO-WORLD-TEXT_
  tar-string = client.send-request "toit/archive" {"uri": untitled-uri}
  content = base64.decode tar-string
  writer = file.Stream.for-write archive-path
  (Writer writer).write content
  writer.close

  lines := run-toit toitc [archive-path, "world"]
  expect-equals 1 lines.size
  expect-equals "hello world" lines.first

  // Test that we can use the archive to create a snapshot.
  run-toit toitc ["-w", snapshot-path, archive-path]
  lines = run-toit toitc [snapshot-path, "world"]
  expect-equals 1 lines.size
  expect-equals "hello world" lines.first

  // Test archives with multiple entry points.
  untitled-uri2 := "untitled:Untitled2"
  untitled-path2 := uri-translator.to-path untitled-uri2
  client.send-did-open --uri=untitled-uri2 --text=GOOD-BYE-WORLD-TEXT_
  tar-string = client.send-request "toit/archive" {"uris": [untitled-uri, untitled-uri2]}
  content = base64.decode tar-string
  writer = file.Stream.for-write archive-path
  (Writer writer).write content
  writer.close

  lines = run-toit toitc [archive-path,
                          "-Xarchive_entry_path=$untitled-path",
                          "world"]
  expect-equals 1 lines.size
  expect-equals "hello world" lines.first

  lines = run-toit toitc [archive-path,
                          "-Xarchive_entry_path=$untitled-path2",
                          "world"]
  expect-equals 1 lines.size
  expect-equals "good bye world" lines.first

  // Test that we can use the archive to create a snapshot.
  run-toit toitc ["-w",
                  "-Xarchive_entry_path=$untitled-path",
                  snapshot-path,
                  archive-path]
  lines = run-toit toitc [snapshot-path, "world"]
  expect-equals 1 lines.size
  expect-equals "hello world" lines.first

  run-toit toitc ["-w",
                  "-Xarchive_entry_path=$untitled-path2",
                  snapshot-path,
                  archive-path]
  lines = run-toit toitc [snapshot-path, "world"]
  expect-equals 1 lines.size
  expect-equals "good bye world" lines.first

  // Test that we can create archives without the SDK.
  untitled-uri3 := "untitled:Untitled3"
  untitled-path3 := uri-translator.to-path untitled-uri3
  client.send-did-open --uri=untitled-uri3 --text=HELLO-WORLD-TEXT_
  tar-string = client.send-request "toit/archive" {
    "uris": [untitled-uri3],
    "includeSdk": false,
  }
  content = base64.decode tar-string
  writer = file.Stream.for-write archive-path
  (Writer writer).write content
  writer.close

  lines = run-toit toitc [archive-path,
                          "-Xarchive_entry_path=$untitled-path3",
                          "world"]
  expect-equals 1 lines.size
  expect-equals "hello world" lines.first

  // Test that we can create a bundle from the archive.
  run-toit toitc ["-w",
                  "-Xarchive_entry_path=$untitled-path3",
                  snapshot-path,
                  archive-path]
  lines = run-toit toitc [snapshot-path, "world"]
  expect-equals 1 lines.size
  expect-equals "hello world" lines.first

main args:
  toitc := args[0]
  toitlsp-exe := args[3]

  dir := directory.mkdtemp "/tmp/test-repro-"
  repro-path := "$dir/repro.tar"
  repro-no-content-path := "$dir/repro_no_content.tar"
  archive-path := "$dir/archive.tar"
  snapshot-path := "$dir/repro.snap"
  try:
    compiler-input := create-archive repro-path toitc
    test-repro-server repro-path toitc toitlsp-exe compiler-input
    run-client-test args: archive-test archive-path snapshot-path toitc toitlsp-exe it
    run-client-test --use-toitlsp args: archive-test archive-path snapshot-path toitc toitlsp-exe it

  finally:
    directory.rmdir --recursive dir
