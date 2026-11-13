// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ar
import encoding.json
import expect show *
import fs
import host.directory
import host.file
import host.pipe
import .util show EnvelopeTest with-test

/**
Tests installing containers from source. The envelope keeps the sources,
  unless they are stripped, so they can be combined with the system program.
*/

main args:
  with-test args: | test/EnvelopeTest |
    source := "$test.tmp-dir/hello.toit"
    file.write-contents --path=source """
      main: print "hello from source"
      """
    test.firmware ["container", "install", "hello", source]
    test.firmware ["container", "install", "stripped", source, "--strip"]
    containers := list-containers test
    expect-equals true containers["hello"]["source"]
    expect-not (containers["stripped"].contains "source")

    // Without --combine, the containers run their snapshots.
    test.extract-to-dir --dir-path=test.tmp-dir
    output := test.backticks "$test.tmp-dir/ota0"
    expect (output.contains "hello from source")

    // Only ESP32 envelopes can combine containers.
    expect-equals 1 (test.firmware --allow-fail ["extract", "--combine", "--format", "tar", "-o", "$test.tmp-dir/x"])

    test-paths test

    // Uninstalling drops the sources.
    test.firmware ["container", "uninstall", "hello"]
    containers = list-containers test
    expect-not (containers.contains "hello")
    expect-equals 0 (test.firmware --allow-fail ["container", "install", "hello", source, "--strip"])

/**
Tests that the envelope doesn't have the paths of the machine that installed
  a program, neither in its sources nor in the source map of its snapshot,
  and that the snapshot is the one 'toit compile --snapshot -O2' makes.
*/
test-paths test/EnvelopeTest:
  project := "$test.tmp-dir/my-app"
  directory.mkdir --recursive "$project/src"
  file.write-contents --path="$project/package.yaml" ""
  file.write-contents --path="$project/src/util.toit" """
    greet: print "hello from my-app"
    """
  source := "$project/src/main.toit"
  file.write-contents --path=source """
    import .util
    main: greet
    """
  test.firmware ["container", "install", "my-app", source]
  test.firmware ["container", "install", "-o", "$test.tmp-dir/stripped.envelope", "my-app", source, "--strip"]

  sdk := fs.dirname (fs.dirname (fs.to-absolute test.toit-bin))
  [test.envelope, "$test.tmp-dir/stripped.envelope"].do: | path/string |
    content := (file.read-contents path).to-string-non-throwing
    expect-not (content.contains test.tmp-dir)
    expect-not (content.contains sdk)
  expect ((file.read-contents test.envelope).to-string-non-throwing.contains "/my-app/src/main.toit")

  installed := "$test.tmp-dir/installed.snapshot"
  test.firmware ["container", "extract", "my-app", "--part", "image", "-o", installed]
  compiled := "$test.tmp-dir/compiled.snapshot"
  exit-code := pipe.run-program [test.toit-bin, "compile", "--snapshot", "-O2", "-o", compiled, source]
  expect-equals 0 exit-code
  expect-equals (snapshot-uuid compiled) (snapshot-uuid installed)

snapshot-uuid path/string -> ByteArray:
  reader := ar.ArReader.from-bytes (file.read-contents path)
  while entry := reader.next:
    if entry.name == "uuid": return entry.content
  throw "No uuid in $path"

list-containers test/EnvelopeTest -> Map:
  path := "$test.tmp-dir/containers.json"
  test.firmware ["container", "list", "-o", path]
  return json.decode (file.read-contents path)
