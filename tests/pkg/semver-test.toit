// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ...tools.pkg.semantic-version

compare v1 v2:
  return (SemanticVersion v1) < (SemanticVersion v2)

main:
  v := SemanticVersion "0.1.0"
  expect-equals 0 v.major
  expect-equals 1 v.minor
  expect-equals 0 v.patch

  v = SemanticVersion "1.2.4533321-alpha.2.2.2+BBA---34.0-3.0133k.42"
  expect-equals 1 v.major
  expect-equals 2 v.minor
  expect-equals 4533321 v.patch
  expect-equals ["alpha",2,2,2] v.pre-releases
  expect-equals ["BBA---34", "0-3", "0133k", "42"] v.build-numbers

  expect-equals true (compare "0.1.0" "0.1.1")
  expect-equals true (compare "0.1.0" "1.0.0")
  expect-equals true (compare "0.222222.0" "1.0.0")
  expect-equals true (compare "1.0.0-alpha" "1.0.0")
  expect-equals true (compare "1.0.0-alpha" "1.0.0-beta")
  expect-equals false (compare "1.0.0" "1.0.0-beta")
  expect-equals true (compare "2.1.2" "3.0.0")

  expect-equals true (compare "2.0.0-alpha.79" "2.0.0-alpha.121.31+pgk-in-toit.95591318")
  expect-equals true (compare "2.0.0-alpha.121.31+pgk-in-toit.95591318" "3.0.0")


  expect-throw "Parse error, expected a numeric value at position 0" : SemanticVersion "."
  expect-throw "Parse error, expected a numeric value at position 4" : SemanticVersion "1.1."
  expect-throw "Parse error, not all input was consumed" : SemanticVersion "1.1.02"
  expect-throw "Parse error, expected . at position 3" : SemanticVersion "1.01.2"
  expect-throw "Parse error in pre-release, expected an identifier or a number at position 6" : SemanticVersion "1.1.2-"
  expect-throw "Parse error in build-number, expected an identifier or digits at position 6" : SemanticVersion "1.1.2+"