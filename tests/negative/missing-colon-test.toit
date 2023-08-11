// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  if 12 < 43
    print "Hello, World!"

  for i := 0; i < 10: i++:
    print "Nah then, nah then, nah then!"

  try
    print "No colon for you!"

  print "Spacer\n"

  try:
    print "This works"
  finally
    print "But no colon again"

  if 4 == 5:
    print "Not likely"
  else
    print "More like it"

  while 1 == 2
    print "Just keep doing it"


class Point
  x/int
  y/int

  foo -> int
    return x + y
