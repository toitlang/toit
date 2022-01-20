// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

test_while:
  while
  while break
    print unresolved
  while break print unresolved
  while "".
  while:
  unresolved

main:
  test_while
