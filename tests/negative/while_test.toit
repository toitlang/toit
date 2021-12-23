// Copyright (C) 2019 Toitware ApS. All rights reserved.

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
