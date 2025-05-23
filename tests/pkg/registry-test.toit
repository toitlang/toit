// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import fs
import host.os
import host.directory
import host.file
import system

import encoding.yaml

import .setup
import .utils_

import ...tools.pkg.registry
import ...tools.pkg.registry.git
import ...tools.pkg.registry.local
import ...tools.pkg.registry.description
import ...tools.pkg.semantic-version

test-git:
  registry := GitRegistry "toit" "github.com/toitware/registry" "1f76f33242ddcb7e71ff72be57c541d969aabfb2"

  expect-equals 558 registry.list-all-descriptions.size

  morse-1-0-6 := registry.retrieve-description
      "github.com/toitware/toit-morse"
      SemanticVersion.parse "1.0.6"
  expect-equals "github.com/toitware/toit-morse" morse-1-0-6.url
  expect-equals (SemanticVersion.parse "1.0.6") morse-1-0-6.version
  expect-equals "morse" morse-1-0-6.name
  expect-equals "Functions for International (ITU) Morse code." morse-1-0-6.description

  morse-versions := registry.retrieve-versions "github.com/toitware/toit-morse"
  expect-equals 5 morse-versions.size
  morse-versions.sort --in-place
  expect-equals "[1.0.0, 1.0.1, 1.0.2, 1.0.5, 1.0.6]" morse-versions.stringify

  morse-search := registry.search "toit-morse"
  expect-equals 1 morse-search.size
  expect-equals "1.0.6" (morse-search[0] as Description).version.stringify

  morse-search = registry.search "toit-morse@1"
  expect-equals 1 morse-search.size
  expect-equals "1.0.6" (morse-search[0] as Description).version.stringify

  morse-search = registry.search "toit-morse@1.0.2"
  expect-equals 1 morse-search.size
  expect-equals "1.0.2" (morse-search[0] as Description).version.stringify

  morse-search = registry.search "morse@1.0.2"
  expect-equals 1 morse-search.size
  expect-equals "1.0.2" (morse-search[0] as Description).version.stringify

  morse-search = registry.search "morse"
  expect-equals 1 morse-search.size
  expect-equals "1.0.6" (morse-search[0] as Description).version.stringify

  host-search := registry.search "pkg-host"
  expect-equals 1 host-search.size
  expect-equals "1.11.0" (host-search[0] as Description).version.stringify

  expect-equals 4 (registry.search --free-text "I2C").size
  expect-equals 23 (registry.search --free-text "host").size

  expect-equals 2 (registry.search "test").size

test-local:
  registry := LocalRegistry "local" "input/registry"

  expect-equals 3 registry.list-all-descriptions.size

  morse-1-0-6 := registry.retrieve-description
      "github.com/toitware/toit-morse-local"
      SemanticVersion.parse "1.0.6"
  expect-equals "github.com/toitware/toit-morse-local" morse-1-0-6.url
  expect-equals (SemanticVersion.parse "1.0.6") morse-1-0-6.version
  expect-equals "morse" morse-1-0-6.name
  expect-equals "Functions for International (ITU) Morse code." morse-1-0-6.description

  morse-versions := registry.retrieve-versions "github.com/toitware/toit-morse-local"
  expect-equals 2 morse-versions.size
  morse-versions.sort --in-place
  expect-equals "[1.0.1, 1.0.6]" morse-versions.stringify

  morse-search := registry.search "toit-morse-local"
  expect-equals 1 morse-search.size
  expect-equals "1.0.6" (morse-search[0] as Description).version.stringify

  host-search := registry.search "pkg-host-local"
  expect-equals 1 host-search.size
  expect-equals "1.11.0" (host-search[0] as Description).version.stringify

  expect-equals 2 (registry.search "local").size

test-registries:
  test-ui := TestUi

  test-registries := Registries --ui=test-ui

  test-registries.list
  expect-equals
      """
      Name       Type   Url/Path
      ----       ----   --------
      toit       git    github.com/toitware/registry"""
      test-ui.stdout
  test-ui.stdout = ""

  test-registries.add --local "local" "input/registry"
  test-registries.list
  expect-equals
      """
      Name       Type   Url/Path
      ----       ----   --------
      toit       git    github.com/toitware/registry
      local      local  input/registry"""
      test-ui.stdout
  test-ui.stdout = ""

  test-registries.remove "local"
  test-registries.list
  expect-equals
      """
      Name       Type   Url/Path
      ----       ----   --------
      toit       git    github.com/toitware/registry"""
      test-ui.stdout
  test-ui.stdout = ""

  expect-throw "Registry toit already exists." : test-registries.add --local "toit" ""
  expect-throw "Registry toit already exists." : test-registries.add --git "toit" ""
  expect-throw "Registry abc does not exist." : test-registries.remove "abc"

  test-registries.add --git "toit2" "github.com/toitware/registry"
  test-registries.list
  expect-equals
      """
      Name       Type   Url/Path
      ----       ----   --------
      toit       git    github.com/toitware/registry
      toit2      git    github.com/toitware/registry"""
      test-ui.stdout
  test-ui.stdout = ""

  test-registries.remove "toit2"
  test-registries.list
  expect-equals
      """
      Name       Type   Url/Path
      ----       ----   --------
      toit       git    github.com/toitware/registry"""
      test-ui.stdout
  test-ui.stdout = ""

  test-registries.add --local "local" "input/registry"
  expect-equals 2 test-registries.list-packages.size

  morse-versions := test-registries.retrieve-versions "github.com/toitware/toit-morse"
  expect-equals 5 morse-versions.size
  expect-equals "[1.0.6, 1.0.5, 1.0.2, 1.0.1, 1.0.0]" morse-versions.stringify

  morse-1-0-6 := test-registries.retrieve-description
      "github.com/toitware/toit-morse-local"
      SemanticVersion.parse "1.0.6"
  expect-equals "github.com/toitware/toit-morse-local" morse-1-0-6.url
  expect-equals (SemanticVersion.parse "1.0.6") morse-1-0-6.version
  expect-equals "morse" morse-1-0-6.name
  expect-equals "Functions for International (ITU) Morse code." morse-1-0-6.description

  expect-equals 8 (test-registries.search --free-text "morse").size

  expect-throw "Package 'morse' not found in registry local." : test-registries.search --registry-name="local" "morse"
  expect-throw "Package 'mrse' not found in any registry." : test-registries.search "mrse"
  expect-throw "Package 'morse' exists but not with version '2' in any registry." : test-registries.search "morse@2"
  expect-throw "Package 'morse-local' exists but not with version '2' in registry local." : test-registries.search --registry-name="local"  "morse-local@2"
  expect-throw "Multiple packages found for 'local' in all registries." : test-registries.search  "local"

main:
  source-location := system.program-path
  source-dir := fs.dirname source-location
  directory.chdir source-dir

  with-test-registry:
    test-git
    test-local
    test-registries

