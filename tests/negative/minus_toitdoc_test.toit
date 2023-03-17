// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
  $foo- OK because not followed by identifier character.
  $foo-b  // Warning, since that would become a single identifier.
  $foo-3  // Same warning.
  $foo-3.5  // Same warning.
  $foo-=  // OK
  $foo--  // OK
  $foo-$bar // Conservative warning that isn't necessary.
*/
foo:
  unresolved

bar:
