// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.directory
import host.file
import host.pipe

import ...tools.mcp.lock-file-cache show LockFileCache

main:
  test-resolve-by-url
  test-resolve-by-prefix
  test-resolve-version-by-url
  test-resolve-version-by-prefix
  test-unknown-url
  test-unknown-prefix
  test-path-points-to-toit-files
  test-no-lock-file

/**
Creates a temporary project directory with a real package installed.

Calls the given $block with the temporary directory path.
*/
with-test-project [block] -> none:
  tmp-dir := directory.mkdtemp "/tmp/mcp-lock-test-"
  try:
    pipe.run-program ["toit", "pkg", "init", "--project-root=$tmp-dir"]
    pipe.run-program ["toit", "pkg", "install", "morse", "--project-root=$tmp-dir"]
    block.call tmp-dir
  finally:
    directory.rmdir --recursive --force tmp-dir

test-resolve-by-url:
  with-test-project: | project-root/string |
    cache := LockFileCache project-root
    path := cache.resolve-path --url="github.com/toitware/toit-morse"
    expect (path.contains ".packages")
    expect (path.contains "github.com/toitware/toit-morse")

test-resolve-by-prefix:
  with-test-project: | project-root/string |
    cache := LockFileCache project-root
    path := cache.resolve-path --prefix="morse"
    expect (path.contains ".packages")
    expect (path.contains "github.com/toitware/toit-morse")

test-resolve-version-by-url:
  with-test-project: | project-root/string |
    cache := LockFileCache project-root
    version := cache.resolve-version --url="github.com/toitware/toit-morse"
    expect-not-null version
    // The version should be a semantic version string.
    expect (version.contains ".")

test-resolve-version-by-prefix:
  with-test-project: | project-root/string |
    cache := LockFileCache project-root
    version := cache.resolve-version --prefix="morse"
    expect-not-null version
    expect (version.contains ".")

test-unknown-url:
  with-test-project: | project-root/string |
    cache := LockFileCache project-root
    // Unknown URL should throw.
    exception := catch:
      cache.resolve-path --url="github.com/nonexistent/package"
    expect-not-null exception

    // Unknown URL version should return null.
    version := cache.resolve-version --url="github.com/nonexistent/package"
    expect-null version

test-unknown-prefix:
  with-test-project: | project-root/string |
    cache := LockFileCache project-root
    // Unknown prefix should throw.
    exception := catch:
      cache.resolve-path --prefix="nonexistent"
    expect-not-null exception

    // Unknown prefix version should return null.
    version := cache.resolve-version --prefix="nonexistent"
    expect-null version

test-path-points-to-toit-files:
  with-test-project: | project-root/string |
    cache := LockFileCache project-root
    path := cache.resolve-path --url="github.com/toitware/toit-morse"
    // The resolved path should exist on disk.
    expect (file.is-directory path)
    // The package should have a src/ directory with .toit files.
    src-dir := "$path/src"
    expect (file.is-directory src-dir)
    // Check that there is at least one .toit file.
    found-toit-file := false
    stream := directory.DirectoryStream src-dir
    try:
      while entry := stream.next:
        if entry.ends-with ".toit":
          found-toit-file = true
          // Verify the file is readable and non-empty.
          content := file.read-contents "$src-dir/$entry"
          expect (content.size > 0)
    finally:
      stream.close
    expect found-toit-file

test-no-lock-file:
  tmp-dir := directory.mkdtemp "/tmp/mcp-lock-test-"
  try:
    // No lock file exists, so lookups should fail gracefully.
    cache := LockFileCache tmp-dir
    version := cache.resolve-version --url="github.com/toitware/toit-morse"
    expect-null version
    version2 := cache.resolve-version --prefix="morse"
    expect-null version2
  finally:
    directory.rmdir --recursive --force tmp-dir
