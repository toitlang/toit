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
import host.tar show Tar
import writer show Writer

import .lsp_client show LspClient run_client_test
import .utils

import ...tools.lsp.server.compiler
import ...tools.lsp.server.uri_path_translator
import ...tools.lsp.server.documents
import ...tools.lsp.server.file_server
import ...tools.lsp.server.repro
import ...tools.lsp.server.tar_utils

read_all_lines reader/BufferedReader:
  lines := []
  while true:
    line := reader.read_line
    if line == null: return lines
    lines.add line

UNTITLED_TEXT_ ::= """
  foo: return 499
  main: f
  """

HELLO_WORLD_TEXT_ ::= """
  main args: print "hello \$args[0]"
  """

GOOD_BYE_WORLD_TEXT_ ::= """
  main args: print "good bye \$args[0]"
  """

create_compiler_input --path/string:
  line_number := 1
  column_number := 7
  return "COMPLETE\n$path\n$line_number\n$column_number\n"

check_compiler_output reader/BufferedReader:
  suggestions := read_all_lines reader
  expect (suggestions.contains "foo")

/**
Creates a tar archive at the given $path.

Returns a `compiler-input`. When running the repro with that input, it should
  yield a result that checks successfully $check_compiler_output.
*/
create_archive path toitc -> string:
  uri_translator := UriPathTranslator
  documents := Documents uri_translator

  untitled_uri := "untitled:Untitled1"
  untitled_path := uri_translator.to_path untitled_uri

  documents.did_open --uri=untitled_uri UNTITLED_TEXT_ 1
  timeout_ms := -1  // No timeout.

  repro_filesystem := FilesystemLocal (sdk_path_from_compiler toitc)
  protocol := FileServerProtocol documents repro_filesystem
  compiler := Compiler toitc uri_translator timeout_ms
      --protocol=protocol
      --project_path=directory.cwd

  compiler_input := create_compiler_input --path=untitled_path

  suggestions := null
  compiler.run --compiler_input=compiler_input:
    check_compiler_output it

  write_repro
      --repro_path=path
      --compiler_flags=compiler.build_run_flags
      --compiler_input=compiler_input
      --info="Test"
      --protocol=protocol
      --cwd_path=directory.cwd
      --include_sdk

  print "created $path"

  return compiler_input

/**
Runs the compiler using the repro archive.
*/
test_repro_server archive_path toitc toitlsp compiler_input:
  cpp_pipes := pipe.fork
      true                // use_path
      pipe.PIPE_CREATED   // stdin
      pipe.PIPE_CREATED   // stdout
      pipe.PIPE_INHERITED // stderr
      toitc
      [
        toitc,
        "--lsp",
      ]
  cpp_to   := cpp_pipes[0]
  cpp_from := cpp_pipes[1]
  cpp_pid  := cpp_pipes[3]

  // Start the repro server and extract the port from its output.
  // We use the `--json` flag to make that easier.
  port/int := ?
  toitlsp_pipes := pipe.fork
      true                // use_path
      pipe.PIPE_CREATED   // stdin
      pipe.PIPE_CREATED   // stdout
      pipe.PIPE_INHERITED // stderr
      toitlsp
      [toitlsp, "repro", "serve", "--json", archive_path]
  toitlsp_to := toitlsp_pipes[0]
  toitlsp_from := toitlsp_pipes[1]
  toitlsp_pid := toitlsp_pipes[3]
  r := BufferedReader toitlsp_from
  while true:
    if line := r.read_line:
      result := json.parse line
      port = result["port"]
      toitlsp_from.close
      break

  try:
    writer := Writer cpp_to
    writer.write "$port\n"
    writer.write compiler_input
  finally:
    cpp_to.close

  try:
    check_compiler_output (BufferedReader cpp_from)
  finally:
    cpp_from.close

  pipe.kill_ toitlsp_pid 9
  pipe.wait_for toitlsp_pid

archive_test
    archive_path/string
    snapshot_path/string
    toitc/string
    toitlsp/string
    client/LspClient:
  uri_translator := UriPathTranslator
  untitled_uri := "untitled:Untitled1"
  untitled_path := uri_translator.to_path untitled_uri

  client.send_did_open --uri=untitled_uri --text=UNTITLED_TEXT_
  tar_string := client.send_request "toit/archive" {"uri": untitled_uri}
  content := base64.decode tar_string
  writer := file.Stream.for_write archive_path
  (Writer writer).write content
  writer.close

  compiler_input := create_compiler_input --path=untitled_path
  test_repro_server archive_path toitc toitlsp compiler_input

  client.send_did_change --uri=untitled_uri HELLO_WORLD_TEXT_
  tar_string = client.send_request "toit/archive" {"uri": untitled_uri}
  content = base64.decode tar_string
  writer = file.Stream.for_write archive_path
  (Writer writer).write content
  writer.close

  lines := run_toit toitc [archive_path, "world"]
  expect_equals 1 lines.size
  expect_equals "hello world" lines.first

  // Test that we can use the archive to create a snapshot.
  run_toit toitc ["-w", snapshot_path, archive_path]
  lines = run_toit toitc [snapshot_path, "world"]
  expect_equals 1 lines.size
  expect_equals "hello world" lines.first

  // Test archives with multiple entry points.
  untitled_uri2 := "untitled:Untitled2"
  untitled_path2 := uri_translator.to_path untitled_uri2
  client.send_did_open --uri=untitled_uri2 --text=GOOD_BYE_WORLD_TEXT_
  tar_string = client.send_request "toit/archive" {"uris": [untitled_uri, untitled_uri2]}
  content = base64.decode tar_string
  writer = file.Stream.for_write archive_path
  (Writer writer).write content
  writer.close

  lines = run_toit toitc [archive_path,
                          "-Xarchive_entry_path=$untitled_path",
                          "world"]
  expect_equals 1 lines.size
  expect_equals "hello world" lines.first

  lines = run_toit toitc [archive_path,
                          "-Xarchive_entry_path=$untitled_path2",
                          "world"]
  expect_equals 1 lines.size
  expect_equals "good bye world" lines.first

  // Test that we can use the archive to create a snapshot.
  run_toit toitc ["-w",
                  "-Xarchive_entry_path=$untitled_path",
                  snapshot_path,
                  archive_path]
  lines = run_toit toitc [snapshot_path, "world"]
  expect_equals 1 lines.size
  expect_equals "hello world" lines.first

  run_toit toitc ["-w",
                  "-Xarchive_entry_path=$untitled_path2",
                  snapshot_path,
                  archive_path]
  lines = run_toit toitc [snapshot_path, "world"]
  expect_equals 1 lines.size
  expect_equals "good bye world" lines.first

  // Test that we can create archives without the SDK.
  untitled_uri3 := "untitled:Untitled3"
  untitled_path3 := uri_translator.to_path untitled_uri3
  client.send_did_open --uri=untitled_uri3 --text=HELLO_WORLD_TEXT_
  tar_string = client.send_request "toit/archive" {
    "uris": [untitled_uri3],
    "includeSdk": false,
  }
  content = base64.decode tar_string
  writer = file.Stream.for_write archive_path
  (Writer writer).write content
  writer.close

  lines = run_toit toitc [archive_path,
                          "-Xarchive_entry_path=$untitled_path3",
                          "world"]
  expect_equals 1 lines.size
  expect_equals "hello world" lines.first

  // Test that we can create a bundle from the archive.
  run_toit toitc ["-w",
                  "-Xarchive_entry_path=$untitled_path3",
                  snapshot_path,
                  archive_path]
  lines = run_toit toitc [snapshot_path, "world"]
  expect_equals 1 lines.size
  expect_equals "hello world" lines.first

main args:
  toitc := args[0]
  toitlsp_exe := args[3]

  dir := directory.mkdtemp "/tmp/test-repro-"
  repro_path := "$dir/repro.tar"
  repro_no_content_path := "$dir/repro_no_content.tar"
  archive_path := "$dir/archive.tar"
  snapshot_path := "$dir/repro.snap"
  try:
    compiler_input := create_archive repro_path toitc
    test_repro_server repro_path toitc toitlsp_exe compiler_input
    run_client_test args: archive_test archive_path snapshot_path toitc toitlsp_exe it
    run_client_test --use_toitlsp args: archive_test archive_path snapshot_path toitc toitlsp_exe it

  finally:
    directory.rmdir --recursive dir
