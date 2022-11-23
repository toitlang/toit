// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  get_smi
  get_string
  get_smi_or_string

get_smi:
  return 42

get_string:
  return "hest"

get_smi_or_string:
  x := get_smi
  if x == 0: return x
  return get_string
