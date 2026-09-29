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

  objects := (inspect.call ["objects", "--process", "$process-id", "--class", "Node", "--limit", "1000", first])[0]["result"]
  live := objects.filter: it["live"]
  expect-equals 501 live.size

  // The strings have previews, so they can be found by their content.
  strings := (inspect.call ["objects", "--process", "$process-id", "--class", "String_", "--limit", "10000", first])[0]["result"]
  address-of := : | text/string | (strings.filter: it["preview"] == text)[0]["address"]

  // "node 499" is the value of the head of the retained list.
  path := inspect.call ["path", first, address-of.call "node 499"]
  expect-equals "global" path[0]["root"]
  expect-equals "retained-nodes" path[0]["global"]
  expect-equals 2 path.size
  address := path[0]["address"]
  expect-equals "value" path[1]["referenced-by-field"]

  object := inspect.call ["object", first, address]
  expect-equals "Node" object["class"]
  field-names := object["fields"].map: it["name"]
  expect-equals ["value", "next"] field-names
  expect-equals "node 499" object["fields"][0]["value"]["preview"]

  held-path := inspect.call ["path", first, address-of.call "held by finalizer 1"]
  expect-equals "finalizer" held-path[0]["root"]

  retainers := inspect.call ["retainers", first, address]
  expect retainers.size >= 1
