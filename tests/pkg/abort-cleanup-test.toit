// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import fs
import host.directory
import host.file
import host.pipe

main args/List:
  expect-equals 1 args.size
  toit-exe/string := args[0]
  tmp-dir := directory.mkdtemp "/tmp/pkg-abort-cleanup-"
  try:
    local-dir := fs.join tmp-dir "local"
    directory.mkdir --recursive (fs.join local-dir "src")
    file.write-contents --path=(fs.join tmp-dir "package.yaml") "# Toit Package File.\n"
    file.write-contents --path=(fs.join local-dir "package.yaml") """
        name: local
        description: Local package with an unavailable dependency.
        dependencies:
          missing:
            url: invalid.local/missing
            version: ^1.0.0
        """

    exit-code := pipe.run-program [
      toit-exe,
      "pkg",
      "--project-root=$tmp-dir",
      "--no-auto-sync",
      "install",
      "--local",
      local-dir,
    ]
    expect-equals 1 exit-code
    expect-not (file.is-directory (fs.join tmp-dir ".packages/.lock"))
  finally:
    directory.rmdir --recursive --force tmp-dir
