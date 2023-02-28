// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

toto x y: return x - y

main:
  foo := 1
  bar := 2

  print foo-bar
  print foo- bar
  toto foo -bar  // This is a valid use where only bar is inverted.
  
  print foo - bar
  print (foo - bar)

  unresolved
