// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.yaml
import expect show *
import host.directory
import host.file
import host.pipe

import .gold-tester

TEST-HASH ::= "deadbeef1234567890abcdef1234567890abcdef"

main args:
  with-gold-tester args --with-git-pkg-registry: test it

test tester/GoldTester:
  tester.gold "10-install" [
    ["pkg", "init"],
    ["pkg", "install", "localhost:$tester.port/pkg/pkg1"],
    ["pkg", "install", "localhost:$tester.port/pkg/pkg2"],
    ["exec", "main.toit"],
    ["package.lock"],
    ["contents.json"],
  ]

  directory.rmdir --force --recursive "$tester.working-dir/.packages"
  lock-path := "$tester.working-dir/package.lock"
  lock-content-encoded := file.read-contents lock-path
  decoded := yaml.decode lock-content-encoded
  decoded["packages"].map --in-place: | _ entry/Map |
    // For testing all hashes are set to TEST-HASH.
    // Replace it with the actual hash.
    expect-equals TEST-HASH entry["hash"]
    // Run git to retrieve the actual hash.
    tag-line := pipe.backticks [
      "git", "ls-remote", "http://$(entry["url"])", "refs/tags/v$entry["version"]",
    ]
    tag-line = tag-line.replace --all "\t" " "
    actual-hash := tag-line[..tag-line.index-of " "]
    entry["version"] = "42.31.9"
    entry["hash"] = actual-hash.trim
    entry

  encoded := yaml.encode decoded
  file.write-contents --path=lock-path encoded

  tester.gold "20-reinstall" [
    ["package.lock"],
    ["// Install doesn't look at the version when there is a hash."],
    ["pkg", "install"],
    ["exec", "main.toit"],
    ["contents.json"],
  ]
