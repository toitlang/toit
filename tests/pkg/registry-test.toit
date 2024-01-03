import expect show *
import host.os
import host.directory
import host.file

import encoding.yaml

import ...tools.pkg.registry
import ...tools.pkg.registry.git
import ...tools.pkg.registry.local
import ...tools.pkg.registry.description
import ...tools.pkg.semantic-version

test-git:
  registry := GitRegistry "toit" "github.com/toitware/registry" "1f76f33242ddcb7e71ff72be57c541d969aabfb2"

  expect-equals 558 registry.list-all-descriptions.size

  morse-1-0-6 := registry.retrieve-description "github.com/toitware/toit-morse" (SemanticVersion "1.0.6")
  expect-equals "github.com/toitware/toit-morse" morse-1-0-6.url
  expect-equals (SemanticVersion "1.0.6") morse-1-0-6.version
  expect-equals "morse" morse-1-0-6.name
  expect-equals "Functions for International (ITU) Morse code." morse-1-0-6.description

  morse-versions := registry.retrieve-versions "github.com/toitware/toit-morse"
  expect-equals 5 morse-versions.size
  expect-equals "[1.0.6, 1.0.5, 1.0.2, 1.0.1, 1.0.0]" morse-versions.stringify

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

  morse-1-0-6 := registry.retrieve-description "github.com/toitware/toit-morse-local" (SemanticVersion "1.0.6")
  expect-equals "github.com/toitware/toit-morse-local" morse-1-0-6.url
  expect-equals (SemanticVersion "1.0.6") morse-1-0-6.version
  expect-equals "morse" morse-1-0-6.name
  expect-equals "Functions for International (ITU) Morse code." morse-1-0-6.description

  morse-versions := registry.retrieve-versions "github.com/toitware/toit-morse-local"
  expect-equals 2 morse-versions.size
  expect-equals "[1.0.6, 1.0.1]" morse-versions.stringify

  morse-search := registry.search "toit-morse-local"
  expect-equals 1 morse-search.size
  expect-equals "1.0.6" (morse-search[0] as Description).version.stringify

  host-search := registry.search "pkg-host-local"
  expect-equals 1 host-search.size
  expect-equals "1.11.0" (host-search[0] as Description).version.stringify

  expect-equals 2 (registry.search "local").size

TOIT-REGISTRY-MAP := {
    "url": "github.com/toitware/registry",
    "type": "git",
    "ref-hash": "1f76f33242ddcb7e71ff72be57c541d969aabfb2",
}
LOCAL-REGISTRY-MAP := {
    "path": "input/registry",
    "type": "local"
}

reset-registries-yaml:
  file.write-content --path=".test-cache/registries.yaml"
      yaml.encode {"toit": TOIT-REGISTRY-MAP}


test-registries:
  outputs := []
  reset-registries-yaml

  test-registries := Registries
                       --error-reporter=(:: throw it )
                       --outputter=(:: outputs.add it )

  test-registries.list
  expect-equals
      """
      Name       Type   Url/Path
      ----       ----   --------
      toit       git    github.com/toitware/registry"""
      outputs.join "\n"
  outputs = []

  test-registries.add --local "local" "input/registry"
  test-registries.list
  expect-equals
      """
      Name       Type   Url/Path
      ----       ----   --------
      toit       git    github.com/toitware/registry
      local      local  input/registry"""
      outputs.join "\n"
  outputs = []

  test-registries.remove "local"
  test-registries.list
  expect-equals
      """
      Name       Type   Url/Path
      ----       ----   --------
      toit       git    github.com/toitware/registry"""
      outputs.join "\n"
  outputs = []

  expect-throw "Registry toit already exists." : test-registries.add --local "toit" ""
  expect-throw "Registry toit already exists." : test-registries.add --git "toit" ""
  expect-throw "Registry abc does not exist." : test-registries.remove "abc"

  // Note: This will invoke sync, so
  test-registries.add --git "toit2" "github.com/toitware/registry"
  test-registries.list
  expect-equals
      """
      Name       Type   Url/Path
      ----       ----   --------
      toit       git    github.com/toitware/registry
      toit2      git    github.com/toitware/registry"""
      outputs.join "\n"
  outputs = []

  test-registries.remove "toit2"
  test-registries.list
  expect-equals
      """
      Name       Type   Url/Path
      ----       ----   --------
      toit       git    github.com/toitware/registry"""
      outputs.join "\n"
  outputs = []

  test-registries.add --local "local" "input/registry"
  expect-equals 2 test-registries.list-packages.size

  morse-versions := test-registries.retrieve-versions "github.com/toitware/toit-morse"
  expect-equals 5 morse-versions.size
  expect-equals "[1.0.6, 1.0.5, 1.0.2, 1.0.1, 1.0.0]" morse-versions.stringify

  morse-1-0-6 := test-registries.retrieve-description "github.com/toitware/toit-morse-local" (SemanticVersion "1.0.6")
  expect-equals "github.com/toitware/toit-morse-local" morse-1-0-6.url
  expect-equals (SemanticVersion "1.0.6") morse-1-0-6.version
  expect-equals "morse" morse-1-0-6.name
  expect-equals "Functions for International (ITU) Morse code." morse-1-0-6.description

  expect-equals 8 (test-registries.search --free-text "morse").size

  expect-throw "Package 'morse' not found in registry local." : test-registries.search --registry-name="local" "morse"
  expect-throw "Package 'mrse' not found in any registry." : test-registries.search "mrse"
  expect-throw "Package 'morse' exists but not with version '2' in any registry." : test-registries.search "morse@2"
  expect-throw "Package 'morse-local' exists but not with version '2' in registry local." : test-registries.search --registry-name="local"  "morse-local@2"
  expect-throw "Multiple packages found for 'local' in all registries." : test-registries.search  "local"

main:
  // Initialize the registries storage
  os.env["TOIT_PKG_CACHE_DIR"] = ".test-cache"
  directory.mkdir --recursive ".test-cache"

  test-git
  test-local
  test-registries