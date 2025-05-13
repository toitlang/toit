// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.pipe
import host.directory
import host.file
import expect show *

main args:
  tmp-dir := directory.mkdtemp "/tmp/diagnostic-test-"
  try:
    input-path := "$tmp-dir/input.toit"
    file.write-contents --path=input-path """
    /// Deprecated.
    foo:
    main: foo
    """
    toitrun := args[0]
    toitc := args[1]
    run-test toitrun [input-path] --no-expect-stdout
    run-test toitc ["--analyze", input-path] --expect-stdout
  finally:
    directory.rmdir --recursive tmp-dir

run-test program args --expect-stdout/bool:
  process := pipe.fork
      --use-path
      --create-stdout
      --create-stderr
      program
      [program] + args
  stdout-bytes := #[]
  task::
    reader := process.stdout.in
    while chunk := reader.read:
      stdout-bytes += chunk

  stderr-bytes := #[]
  task::
    reader := process.stderr.in
    while chunk := reader.read:
      stderr-bytes += chunk

  exit-value := process.wait
  exit-code := pipe.exit-code exit-value

  expect-not-null exit-code
  expect-equals 0 exit-code

  stdout := stdout-bytes.to-string
  stderr := stderr-bytes.to-string
  if expect-stdout:
    expect (stdout.contains "eprecated")
    expect-equals "" stderr
  else:
    expect-equals "" stdout
    expect (stderr.contains "eprecated")
