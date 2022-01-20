// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo optional/int=0:
bar --optional/int=0:

class A:
  field/int := ?

  constructor .field=0:
  constructor.named --.field=0:

main:
  foo null // No warning because argument is optional.
  bar --optional=null  // No warning because argument is optional.

  A null  // No warning because argument is optional.
  A.named --field=null  // No warning because argument is optional.
