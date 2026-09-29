// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.json
import expect show *
import fs
import host.directory
import host.file
import host.pipe

main args:
  toit-exe := args[0]
  sdk-dir := args[1]
  tmp-dir := directory.mkdtemp "/tmp/memory-inspector-test-"
  try:
    run-test toit-exe sdk-dir tmp-dir
  finally:
    directory.rmdir --recursive tmp-dir

run-test toit-exe/string sdk-dir/string tmp-dir/string -> none:
  source := fs.join sdk-dir "tests" "memory-inspector" "capture-source.toit"
  snapshot := fs.join tmp-dir "source.snapshot"
  pipe.backticks [toit-exe, "compile", "--snapshot", "-o", snapshot, source]
  output := pipe.backticks [toit-exe, "run", snapshot]
  first := fs.join tmp-dir "first.txt"
  file.write-contents --path=first output

  // Compile the inspector once, instead of for every query.
  tools-dir := fs.join sdk-dir "tools"
  inspector := fs.join tmp-dir "inspector.snapshot"
  pipe.backticks [
    toit-exe, "compile", "--snapshot", "--project-root", tools-dir,
    "-o", inspector, fs.join tools-dir "memory-inspector" "main.toit",
  ]
  inspect := : | arguments/List |
    json.parse (pipe.backticks [
      toit-exe, "run", inspector, "--", arguments[0], "--snapshot", snapshot,
    ] + arguments[1..])

  summary := inspect.call ["summary", first]
  expect (summary["capture"]["complete"])
  expect-equals "first" summary["capture"]["reason"]
  app := summary["processes"].filter: it["has-snapshot"]
  expect-equals 1 app.size
  process-id := app[0]["id"]

  census := (inspect.call ["census", "--process", "$process-id", "--limit", "100", first])[0]["result"]
  node := (census.filter: it["class"] == "Node")[0]
  // The garbage nodes may or may not have been collected already.
  expect 501 <= node["count"] <= 601
  // The retained nodes, and the node that is held by the finalizer.
  expect-equals 501 node["live-count"]
  byte-arrays := (census.filter: it["class"] == "ByteArray_")[0]
  expect byte-arrays["bytes"] + byte-arrays["external-bytes"] >= 20_000
