// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class throw:
  catch := 22
  throw := 22
  switch := 22
  rethrow := 99

class catch:
class switch:
class rethrow:

throw catch switch:
catch x y z:
switch x y z:
rethrow x y z:

main:
  throw := 499
  catch := 42
  switch := 0
  rethrow := 22
  print throw + catch + switch + rethrow
