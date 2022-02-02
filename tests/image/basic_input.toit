// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  // Don't use 'print' as it might require a boot-process which isn't loaded when
  // just running the image.
  print_ "hello world"
