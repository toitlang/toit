// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import cli.test show TestUi
import expect show *

import ...tools.pkg.constraints
import ...tools.pkg.file-system-view
import ...tools.pkg.project.specification show PackageDependency
import ...tools.pkg.registry as reg
import ...tools.pkg.registry.local as reg
import ...tools.pkg.registry.description
import ...tools.pkg.semantic-version
import ...tools.pkg.solver

main:
  test-transitive
  test-correct-version
  test-highest-version
  test-multiple-versions
  test-cycle
  test-fail-missing-pkg
  test-fail-version
  test-preferred
  test-backtrack
  test-no-backtrack-preferred
  test-2-versions
  test-backtrack-2-versions
  test-uniq-error-message
  test-min-sdk
  test-sdk-version
  test-fail-sdk-version

make-pkg -> Description
    name-version/string
    dep-strings/List=[]
    --min-sdk/SemanticVersion?=null:
  parts := name-version.split "-"
  url := parts[0]
  version/string := parts[1]
  deps := dep-strings.map: | dep-string |
    index := dep-string.index-of " "
    dep-url := dep-string[..index]
    dep-version := dep-string[index + 1..]
    constraint := Constraint.parse dep-version
    PackageDependency dep-url --constraint=constraint

  return Description.for-testing_
      --name="name-for-$url"
      --url=url
      --version=SemanticVersion.parse version
      --min-sdk=min-sdk
      --dependencies=deps
      --ui=TestUi

class TestRegistry extends reg.Registry:
  constructor descriptions/List:
    super.filled "test-reg" descriptions --ui=TestUi

  type -> string: return "test"
  content -> FileSystemView: unreachable
  to-map -> Map: unreachable
  sync --clear-cache/bool: // Do nothing.
  stringify -> string: return "test-reg"
  to-string -> string: return "test-reg"

test-ui/TestUi? := null

make-registries pkgs/List -> reg.Registries:
  registry := TestRegistry pkgs
  test-ui = TestUi
  return reg.Registries.filled { registry.name: registry } --ui=test-ui --no-auto-sync

find-solution solve-for/Description registries/reg.Registries -> Solution?
    --sdk-version/SemanticVersion=(SemanticVersion.parse "1.999.0")
    --preferred/List=[]:
  solver := Solver registries --sdk-version=sdk-version --ui=test-ui

  preferred.do: | desc/Description |
    solver.set-preferred desc.url desc.version

  solve-for-constraint := Constraint
      --simple-constraints=[SimpleConstraint "=" solve-for.version]
      --source="=$solve-for.version"
  min-sdk-version := solve-for.sdk-version
      ? solve-for.sdk-version.to-min-version
      : null
  return solver.solve --min-sdk-version=min-sdk-version [
    PackageDependency solve-for.url --constraint=solve-for-constraint
  ]

check-solution solution/Solution expected/List:
  // Our tests are small enough that we can just do a quadratic check.
  solution.packages.do: | url/string resolved-versions/List |
    found := expected.any: | desc/Description |
      desc.url == url and resolved-versions.any: it == desc.version
    expect found

test-transitive:
  a1 := make-pkg "a-1.7.0" ["b ^1.0.0"]
  b11 := make-pkg "b-1.1.0" ["c >=2.0.0,<3.1.2"]
  c2 := make-pkg "c-2.0.5"
  registries := make-registries [a1, b11, c2]
  solution := find-solution a1 registries
  check-solution solution [a1, b11, c2]

test-correct-version:
  a1 := make-pkg "a-1.7.0" ["b ^1.0.0"]
  b01 := make-pkg "b-0.1.0"
  b11 := make-pkg "b-1.1.0"
  b21 := make-pkg "b-2.1.0"
  registries := make-registries [a1, b01, b11, b21]
  solution := find-solution a1 registries
  check-solution solution [a1, b11]

test-highest-version:
  a1 := make-pkg "a-1.7.0" ["b ^1.0.0"]
  b111 := make-pkg "b-1.1.1"
  b123 := make-pkg "b-1.2.3"
  b21 := make-pkg "b-2.1.0"
  registries := make-registries [a1, b111, b123, b21]
  solution := find-solution a1 registries
  check-solution solution [a1, b123]

test-multiple-versions:
  a1 := make-pkg "a-1.7.0" ["b ^1.0.0", "c ^1.0.0"]
  b111 := make-pkg "b-1.1.1" ["c ^2.0.0"]
  c1 := make-pkg "c-1.2.3"
  c2 := make-pkg "c-2.3.4"
  registries := make-registries [a1, b111, c1, c2]
  solution := find-solution a1 registries
  check-solution solution [a1, b111, c2, c1]

test-cycle:
  a1 := make-pkg "a-1.7.0" ["b ^1.0.0"]
  b111 := make-pkg "b-1.1.1" ["a ^1.0.0"]
  registries := make-registries [a1, b111]
  solution := find-solution a1 registries
  check-solution solution [a1, b111]

test-fail-missing-pkg:
  a1 := make-pkg "a-1.7.0" ["b ^1.0.0"]
  registries := make-registries [a1]
  solution := find-solution a1 registries
  expect-null solution
  output := test-ui.stdout-messages
  expect-equals 1 output.size
  expect-equals "Warning: Package 'b' not found\n" output[0]

test-fail-version:
  a1 := make-pkg "a-1.7.0" ["b ^1.0.0"]
  b234 := make-pkg "b-2.3.4"
  registries := make-registries [a1, b234]
  solution := find-solution a1 registries
  expect-null solution

test-preferred:
  a170 := make-pkg "a-1.7.0" ["b ^1.0.0"]
  b110 := make-pkg "b-1.1.0"
  b111 := make-pkg "b-1.1.1"
  b210 := make-pkg "b-2.1.0"
  registries := make-registries [a170, b110, b111, b210]
  // Prefer "b110".
  solution := find-solution a170 registries --preferred=[b110]
  check-solution solution [a170, b110]

test-backtrack:
  a170 := make-pkg "a-1.7.0" ["b ^1.0.0", "c ^1.0.0"]
  b140 := make-pkg "b-1.4.0"
  b180 := make-pkg "b-1.8.0"
  c100 := make-pkg "c-1.0.0" ["b >=1.0.0,<1.5.0"]
  registries := make-registries [a170, b140, b180, c100]
  solution := find-solution a170 registries
  check-solution solution [a170, b140, c100]

test-no-backtrack-preferred:
  a170 := make-pkg "a-1.7.0" ["b ^1.0.0", "c ^1.0.0"]
  b130 := make-pkg "b-1.3.0"
  b140 := make-pkg "b-1.4.0"
  b180 := make-pkg "b-1.8.0"
  c100 := make-pkg "c-1.0.0" ["b >=1.0.0,<1.5.0"]
  registries := make-registries [a170, b130, b140, b180, c100]
  // With the preferred "b140", no backtracking is needed.
  solution := find-solution a170 registries --preferred=[b130]
  check-solution solution [a170, b130, c100]

test-2-versions:
  a170 := make-pkg "a-1.7.0" ["b ^2.0.0", "c ^1.0.0"]
  b140 := make-pkg "b-1.4.0"
  b180 := make-pkg "b-1.8.0"
  b200 := make-pkg "b-2.0.0"
  c100 := make-pkg "c-1.0.0" ["b >=1.0.0,<1.5.0"]
  registries := make-registries [a170, b140, b180, b200, c100]
  solution := find-solution a170 registries
  check-solution solution [a170, b140, b200, c100]

test-backtrack-2-versions:
  a170 := make-pkg "a-1.7.0" ["b ^2.0.0", "c ^1.0.0", "d <1.5.0"]
  b140 := make-pkg "b-1.4.0"
  b180 := make-pkg "b-1.8.0"
  b200 := make-pkg "b-2.0.0"
  c100 := make-pkg "c-1.0.0" ["b >=1.0.0,<1.5.0"]
  // c150 will conflict with the d-version of a170.
  // This will lead to c100 being selected, which will then require
  // another major version of 'd' (namely b140).
  c150 := make-pkg "c-1.5.0" ["b ^2.0.0", "d ^1.5.8"]
  d140 := make-pkg "d-1.4.0"
  d160 := make-pkg "d-1.6.0"
  registries := make-registries [a170, b140, b180, b200, c100, c150, d140, d160]
  solution := find-solution a170 registries
  check-solution solution [a170, b140, b200, c100, d140]

test-uniq-error-message:
  a170 := make-pkg "a-1.7.0" ["b >=1.0.0", "c >=1.0.0"]
  // The solver will try b200, then b180, each time needing to backtrack because
  // of the bad d-dependency which can't be satisfied.
  // It will re-evaluate the 'c' dependency each time, which has warnings.
  // Similarly, it will encounter the d200 at least twice.
  // These warnings must not be printed multiple times.
  b140 := make-pkg "b-1.4.0"
  b180 := make-pkg "b-1.8.0" ["d >=1.3.0"]
  b200 := make-pkg "b-2.0.0" ["d >=1.3.0"]
  c100 := make-pkg "c-1.0.0"
  c150 := make-pkg "c-1.5.0" ["b >=3.0.0"] // No b-package satisfies this requirement.
  d123 := make-pkg "d-1.2.3"
  d200 := make-pkg "d-1.5.0" ["e >=3.0.0"] // No e-package exists.
  registries := make-registries [a170, b140, b180, b200, c100, c150, d123, d200]
  solution := find-solution a170 registries
  check-solution solution [a170, b140, c100]
  output := test-ui.stdout-messages
  expect-equals 2 output.size
  expect-equals "Warning: No version of 'b' satisfies constraint '>=3.0.0'\n" output[0]
  expect-equals "Warning: Package 'e' not found\n" output[1]

test-min-sdk:
  v110 := SemanticVersion.parse "1.1.0"
  v120 := SemanticVersion.parse "1.2.0"
  v130 := SemanticVersion.parse "1.3.0"
  a170 := make-pkg "a-1.7.0" ["b ^2.0.0", "c ^1.0.0"]
  b140 := make-pkg "b-1.4.0" --min-sdk=v110
  b180 := make-pkg "b-1.8.0" --min-sdk=v130
  b200 := make-pkg "b-2.0.0" --min-sdk=v120
  c100 := make-pkg "c-1.0.0" ["b >=1.0.0,<1.5.0"]
  registries := make-registries [a170, b140, b180, b200, c100]
  solution := find-solution a170 registries
  check-solution solution [a170, b140, b200, c100]

test-sdk-version:
  v110 := SemanticVersion.parse "1.1.0"
  v115 := SemanticVersion.parse "1.1.5"
  v120 := SemanticVersion.parse "1.2.0"
  v130 := SemanticVersion.parse "1.3.0"
  a170 := make-pkg "a-1.7.0" ["b ^1.0.0"]
  b140 := make-pkg "b-1.4.0" --min-sdk=v110
  b160 := make-pkg "b-1.6.0" --min-sdk=v120
  b180 := make-pkg "b-1.8.0" --min-sdk=v130
  registries := make-registries [a170, b140, b160, b180]
  solution := find-solution a170 registries
  check-solution solution [a170, b180]

  solution = find-solution a170 registries --sdk-version=v115
  check-solution solution [a170, b140]

test-fail-sdk-version:
  v105 := SemanticVersion.parse "1.0.5"
  v110 := SemanticVersion.parse "1.1.0"
  v120 := SemanticVersion.parse "1.2.0"
  v130 := SemanticVersion.parse "1.3.0"
  a170 := make-pkg "a-1.7.0" ["b ^1.0.0"]
  b140 := make-pkg "b-1.4.0" --min-sdk=v110
  b160 := make-pkg "b-1.6.0" --min-sdk=v120
  b180 := make-pkg "b-1.8.0" --min-sdk=v130
  registries := make-registries [a170, b140, b160, b180]

  solution := find-solution a170 registries --sdk-version=v105
  expect-null solution
  output := test-ui.stdout-messages
  expect-equals 1 output.size
  expect-equals "Warning: No version of 'b' satisfies constraint '^1.0.0' with SDK version '1.0.5'\n" output[0]

  a170 = make-pkg "a-1.7.0" ["b ^1.0.0"] --min-sdk=v110
  registries = make-registries [a170, b140, b160, b180]
  solution = find-solution a170 registries --sdk-version=v105
  expect-null solution
  output = test-ui.stdout-messages
  expect-equals 1 output.size
  expect-equals "Warning: SDK version '1.0.5' does not satisfy the minimal SDK requirement '^1.1.0'\n" output[0]
