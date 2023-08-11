// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  get-smi
  get-string
  get-smi-or-string

get-smi:
  return 42

get-string:
  return "hest"

get-smi-or-string:
  x := get-smi
  if x == 0: return x
  return get-string
