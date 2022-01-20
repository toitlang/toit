// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

interface A implements C D:

interface B A:

interface C B:

interface D C:

class Z implements C:

main:
  z := Z
