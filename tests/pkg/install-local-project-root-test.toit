// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.yaml
import expect show *
import fs
import host.directory
import host.file
import host.pipe

main args/List:
  expect-equals 1 args.size
  toit-exe/string := args[0]
  tmp-dir := directory.mkdtemp "/tmp/pkg-local-project-root-"
  try:
    package-dir := fs.join tmp-dir "widget"
    tests-dir := fs.join package-dir "tests"
    directory.mkdir --recursive (fs.join package-dir "src")
    directory.mkdir tests-dir

    file.write-contents --path=(fs.join package-dir "package.yaml") """
        name: widget
        description: Minimal local dependency target.
        """
    file.write-contents --path=(fs.join tests-dir "package.yaml") """
        name: widget-tests
        description: Minimal nested test project.
        dependencies:
          widget:
            path: ..
        """

    original-cwd := directory.cwd
    try:
      directory.chdir package-dir
      exit-code := pipe.run-program [
        toit-exe,
        "pkg",
        "--project-root=tests",
        "--no-auto-sync",
        "install",
        "--recompute",
      ]
      expect-equals 0 exit-code
    finally:
      directory.chdir original-cwd

    lock/Map := yaml.decode (file.read-contents (fs.join tests-dir "package.lock"))
    expect-equals ".." lock["packages"]["widget"]["path"]
  finally:
    directory.rmdir --recursive --force tmp-dir
