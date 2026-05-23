// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.file
import host.directory

import .gold-tester

main args:
  with-gold-tester args: test it

test tester/GoldTester:
  directory-stream := directory.DirectoryStream "$tester.working-dir/packages"

  while name := directory-stream.next:
    test-path := "$tester.working-dir/packages/$name"
    expect (file.is-directory test-path)

    tester.gold "test-$name" [
      ["pkg", "describe", test-path],
      ["pkg", "describe", "--verbose", test-path],
    ]


  path := "$tester.working-dir/local-path"

  tester.gold "local-path" [
    ["pkg", "describe", path],
    ["pkg", "describe", "--verbose", path],
    ["pkg", "describe", "--allow-local-deps", path],
    ["pkg", "describe", "--no-allow-local-deps", path],
  ]
