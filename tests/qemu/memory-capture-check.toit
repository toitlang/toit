// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Checks the memory capture that memory-capture.toit printed in QEMU.

Runs the memory inspector on the console log, the way an agent would, and
  checks its answers.

Arguments: toit executable, SDK source directory, console log, envelope.
*/

import encoding.json
import expect show *
import fs
import host.pipe

main args:
  toit := args[0]
  tools-dir := fs.join args[1] "tools"
  log := args[2]
  envelope := args[3]

  inspect := : | command/string arguments/List |
    json.parse (pipe.backticks [
      toit, "run", "--project-root", tools-dir,
      fs.join tools-dir "memory-inspector" "main.toit", "--",
      command, "--envelope", envelope, log,
    ] + arguments)

  summary := inspect.call "summary" []
  expect (summary["capture"]["complete"])
  expect-equals "esp32" summary["capture"]["platform"]
  expect-equals "qemu" summary["capture"]["reason"]
  expect (summary["system-heaps"].any: it["name"] == "internal")

  apps := summary["processes"].filter: it["has-snapshot"] and (it["top-classes"].any: it["class"] == "Node")
  expect-equals 1 apps.size
  app-id := apps[0]["id"]

  // The external byte array is in the system heap and belongs to the app.
  owners := summary["malloc"]["used"]
  app-owner := (owners.filter: it["owner"] == "process $app-id")[0]
  expect app-owner["bytes"] >= 20_000
  // The capture's own memory is labeled.
  expect (owners.any: it["owner"] == "memory capture")

  census := (inspect.call "census" ["--process", "$app-id", "--limit", "100"])[0]["result"]
  node := (census.filter: it["class"] == "Node")[0]
  expect-equals 300 node["live-count"]

  strings := (inspect.call "objects" ["--process", "$app-id", "--class", "String_", "--limit", "1000"])[0]["result"]
  address := (strings.filter: it["preview"] == "node 299")[0]["address"]
  path := inspect.call "path" [address]
  expect-equals "global" path[0]["root"]
  expect-equals "nodes" path[0]["global"]
