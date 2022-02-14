// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  print true || false
  print true && false
  print (!true)
  print !true
  if !true: print "ok"
