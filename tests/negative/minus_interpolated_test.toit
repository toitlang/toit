// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  foo := 499
  bar := 42
  print "$foo-"   // OK because not followed by identifier character.
  print "$foo-b"  // Warning, since that would become a single identifier.
  print "$foo-3"  // Same warning.
  print "$foo-$bar" // OK.
  unresolved
