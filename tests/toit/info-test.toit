// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.json
import expect show *
import host.file
import system

import .utils

main args:
  toit-exe := ToitExecutable args

  test-info-sdk toit-exe
  test-info-pkg toit-exe

test-info-sdk toit-exe/ToitExecutable:
  // Text output should contain the SDK version.
  output := toit-exe.backticks ["info", "sdk"]
  expect (output.contains system.vm-sdk-version)
  expect (output.contains "version")
  expect (output.contains "path")
  expect (output.contains "platform")

  // JSON output should be parseable and have expected fields.
  json-output := toit-exe.backticks ["--output-format", "json", "info", "sdk"]
  parsed := json.parse json-output
  expect-equals system.vm-sdk-version parsed["version"]
  expect (parsed.contains "path")
  expect (parsed.contains "lib-path")
  expect (parsed.contains "bin-path")
  expect (parsed.contains "platform")
  expect-equals system.platform parsed["platform"]

test-info-pkg toit-exe/ToitExecutable:
  with-tmp-dir: | tmp-dir/string |
    lock-content := """
      sdk: ^2.0.0-alpha.189
      prefixes:
        http: pkg-http-2
        mylocal: local-pkg
      packages:
        pkg-http-2:
          url: github.com/toitlang/pkg-http
          version: 2.11.0
          hash: abc123
          prefixes:
            net: pkg-net-1
        pkg-net-1:
          url: github.com/toitlang/pkg-net
          version: 1.3.0
          hash: def456
        local-pkg:
          path: ../my-pkg
      """
    file.write-contents --path="$tmp-dir/package.lock" lock-content

    // Text output should contain prefixes.
    output := toit-exe.backticks ["info", "pkg", "--project-root", tmp-dir]
    expect (output.contains "http")
    expect (output.contains "mylocal")

    // JSON output.
    json-output := toit-exe.backticks [
      "--output-format", "json",
      "info", "pkg",
      "--project-root", tmp-dir,
    ]
    parsed := json.parse json-output
    expect-equals tmp-dir parsed["project-root"]
    expect-equals "^2.0.0-alpha.189" parsed["sdk-constraint"]
    packages := parsed["packages"]
    expect (packages.contains "http")
    expect (packages.contains "mylocal")
    http-entry := packages["http"]
    expect-equals "github.com/toitlang/pkg-http" http-entry["url"]
    expect-equals "2.11.0" http-entry["version"]
    expect (http-entry.contains "path")

    // --package flag: show specific package's imports.
    pkg-json := toit-exe.backticks [
      "--output-format", "json",
      "info", "pkg",
      "--project-root", tmp-dir,
      "--package", "http",
    ]
    pkg-parsed := json.parse pkg-json
    expect-equals "http" pkg-parsed["package"]
    pkg-packages := pkg-parsed["packages"]
    expect (pkg-packages.contains "net")
    net-entry := pkg-packages["net"]
    expect-equals "github.com/toitlang/pkg-net" net-entry["url"]
    expect-equals "1.3.0" net-entry["version"]

    // Missing package.lock should error.
    with-tmp-dir: | empty-dir/string |
      fork-result := toit-exe.fork ["info", "pkg", "--project-root", empty-dir]
      expect-not-equals 0 fork-result.exit-code

    // Unknown --package prefix should error.
    fork-result := toit-exe.fork [
      "info", "pkg",
      "--project-root", tmp-dir,
      "--package", "nonexistent",
    ]
    expect-not-equals 0 fork-result.exit-code
