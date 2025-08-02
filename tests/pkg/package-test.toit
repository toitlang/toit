// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import cli.test show TestUi
import encoding.yaml
import expect show *
import host.directory
import host.file
import system

import .setup

import ...tools.pkg.project
import ...tools.pkg.semantic-version
import ...tools.pkg.registry

project-dir/string := ?

verify-ref package ref:
  lock := yaml.decode (file.read-contents "$project-dir/package.lock")
  expect-equals ref lock["packages"][package]["hash"]

main:
  with-test-registry: | tmp-dir |
    project-dir = "$tmp-dir/project-test-root"

    directory.mkdir project-dir

    ui := TestUi
    config := ProjectConfiguration
      --project-root=project-dir
      --cwd=directory.cwd
      --sdk-version=(SemanticVersion.parse system.vm-sdk-version)
      --ui=ui

    project := Project config --empty-lock-file --ui=ui
    project.save

    project = Project config --ui=ui
    registries := Registries --ui=ui --no-auto-sync

    morse := registries.search "morse" --if-absent=(: unreachable) --if-ambiguous=(: unreachable)
    project.install-remote
        --prefixes=[morse.name]
        --remotes=[morse]
        --constraints=[null]
        --registries=registries
    verify-ref "github.com/toitware/toit-morse-1" "f9f6ba3a04984db16887d7a1051ada8ad30d7db2"

    host := registries.search "pkg-host" --if-absent=(: unreachable) --if-ambiguous=(: unreachable)
    project.install-remote
        --prefixes=[host.name]
        --remotes=[host]
        --constraints=[null]
        --registries=registries
    verify-ref "github.com/toitware/toit-morse-1" "f9f6ba3a04984db16887d7a1051ada8ad30d7db2"
    verify-ref "github.com/toitlang/pkg-host-1" "ff187c2c19d695e66c3dc1d9c09b4dc6bec09088"

    project = Project config --ui=ui
    rest := registries.search "rest-server" --if-absent=(: unreachable) --if-ambiguous=(: unreachable)
    project.install-remote
        --prefixes=[rest.name]
        --remotes=[rest]
        --constraints=[null]
        --registries=registries
    verify-ref "github.com/toitlang/pkg-http-1" "108c436cc990535f5d70c380ef68081c38840f4c"
    verify-ref "github.com/mikkeldamsgaard/pkg-rest-server-1" "2326ed4341d4094f0d2482580d3b29be020554b0"
