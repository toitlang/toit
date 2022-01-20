// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import bytes

foo lambda:
  lambda.call

main:
  foo:: bytes.Buffer
