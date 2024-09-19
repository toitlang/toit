// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  i := 0
  while i: null
  while not i: null
  if i: null
  if not i: null
  while true: null  // No warning.
  while false: null  // No warning.
  while not true: null  // No warning.
  while not false: null  // No warning.
  unresolved
