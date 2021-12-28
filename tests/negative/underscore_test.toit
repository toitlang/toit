// Copyright (C) 2020 Toitware ApS. All rights reserved.

foo _ _:
  // Can't reference '_'
  return _

run [block]:
run fun:

bar:
  run: |_|
    return _
  return run:: |_|
    _

gee:
  _ := 499
  return _

class _:

class A:
  _ := 499

  static _:
  _ x:

  static _ := 42

  constructor._:

  _= x:

_ := 42

_= x:

main:
  _
