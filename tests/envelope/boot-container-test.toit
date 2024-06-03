// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.directory
import host.file
import host.pipe

import .exit-codes
import .util show EnvelopeTest with-test
import .boot-container-source as container

main args:
  with-test args: | test/EnvelopeTest |
    test.install
        --name="container"
        --source-path="./boot-container-source.toit"
        --assets=container.ASSETS
    test.extract-to-dir --dir-path=test.tmp-dir

    hello-snapshot := "$test.tmp-dir/hello.snapshot"
    test.compile --path=hello-snapshot --source="""
      main: print "hello from container"
      """
    arch-flag := test.word-size == 4 ? "-m32" : "-m64"
    hello-image := "$test.tmp-dir/hello-image.toit"
    pipe.run-program [
      test.toit-bin, "tool", "snapshot-to-image",
      arch-flag,
      "--format", "binary",
      "-o", hello-image,
      hello-snapshot,
    ]

    expect-equals 0 (installed-entries test.tmp-dir).size
    print "Do nothing"
    test.boot-run test.tmp-dir --env={
      container.DO-NOTHING: "do-nothing"
    }
    expect-equals 0 (installed-entries test.tmp-dir).size

    print "Install"
    output := test.boot-backticks test.tmp-dir --env={
      container.INSTALL-RUN-IMAGE: hello-image,
      container.TMP-DIR: test.tmp-dir,
    }
    expect (output.contains "hello from container")
    expect-not (output.contains "crash");

    installed := installed-entries test.tmp-dir
    expect-equals 1 installed.size
    installed-uuid := installed.first

    // It's safe to install the same image again.
    print "Install2"
    output = test.boot-backticks test.tmp-dir --env={
      container.INSTALL-RUN-IMAGE: hello-image,
      container.TMP-DIR: test.tmp-dir,
    }
    expect (output.contains "hello from container")
    expect-not (output.contains "crash");

    installed = installed-entries test.tmp-dir
    expect-equals 1 installed.size
    installed-uuid2 := installed.first
    expect-equals installed-uuid installed-uuid2

    print "Run"
    output = test.boot-backticks test.tmp-dir --env={
      container.RUN-IMAGE: installed-uuid
    }
    expect (output.contains "hello from container")
    expect-not (output.contains "crash");

    print "Remove"
    test.boot-run test.tmp-dir --env={
      container.REMOVE-IMAGE: installed-uuid,
    }
    expect-equals 0 (installed-entries test.tmp-dir).size

    // It's safe to remove a non-existing image.
    print "Removing non-existing"
    test.boot-run test.tmp-dir --env={
      container.REMOVE-IMAGE: installed-uuid,
    }

installed-entries path/string -> List:
  dir-path := "$path/ota0/installed-images"
  if not file.is-directory dir-path: return []
  stream := directory.DirectoryStream "$path/ota0/installed-images"
  entries := []
  while entry := stream.next:
    entries.add entry
  stream.close
  return entries
