// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

run x [block]: block.call x

run x func/Lambda: func.call x

main:
  run 499: |x/int|
    x.copy 1
  run 499:: |x/int|
    x.copy 1

  run 0 : |x/int=0| unresolved x
  run 0:: |x/int=0| unresolved x
  run 0 : |.x| unresolved x
  run 0:: |.x| unresolved x
  run 0 : |[x]| unresolved x
  run 0:: |[x]| unresolved x
  run 0:: |it/int=0| unresolved it
