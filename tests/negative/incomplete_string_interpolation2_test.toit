// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  print "$
  unresolved1 // This line is consumed as part of the unterminated string.
  unresolved2 // This line gives an error.
