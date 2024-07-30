// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system
import encoding.yaml

import host.directory
import host.file
import expect show *

import .setup

import ...tools.pkg.project
import ...tools.pkg.semantic-version
import ...tools.pkg.registry

PROJECT-DIR ::= ".project-test-root"

verify-ref package ref:
  lock := yaml.decode (file.read-content "$PROJECT-DIR/package.lock")
  expect-equals ref lock["packages"][package]["hash"]

main:
  with-test-registry:
    if file.is-directory PROJECT-DIR:
      directory.rmdir --recursive PROJECT-DIR

    directory.mkdir PROJECT-DIR
    config := ProjectConfiguration
      --project-root=PROJECT-DIR
      --cwd=directory.cwd
      --sdk-version=(SemanticVersion.parse system.vm-sdk-version)
      --auto-sync=false

    project := Project config --empty-lock-file
    project.save

    project = Project config
    morse := registries.search "morse"
    project.install-remote morse.name morse
    verify-ref "toit-morse" "f9f6ba3a04984db16887d7a1051ada8ad30d7db2"

    host := registries.search "pkg-host"
    project.install-remote host.name host
    verify-ref "toit-morse" "f9f6ba3a04984db16887d7a1051ada8ad30d7db2"
    verify-ref "pkg-host" "7e7df6ac70d98a02f232185add81a06cec0d77e8"

    project = Project config
    rest := registries.search "rest-server"
    project.install-remote rest.name rest
    verify-ref "pkg-http" "108c436cc990535f5d70c380ef68081c38840f4c"
    verify-ref "pkg-rest-server" "2326ed4341d4094f0d2482580d3b29be020554b0"
