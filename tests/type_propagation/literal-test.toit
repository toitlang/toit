// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  get-smi
  get-string
  get-smi-or-string
  get-max-smi32
  get-min-smi32
  get-above-smi32
  get-below-smi32
  get-above-smi64
  get-below-smi64

get-smi:
  return 42

get-string:
  return "hest"

get-max-smi32:
  return 0x3fff_ffff

get-min-smi32:
  return -1_073_741_824

get-above-smi32:
  return 0x4000_0000

get-below-smi32:
  return -1_073_741_825

get-above-smi64:
  return 0x4000_0000_0000_0000

get-below-smi64:
  return -4_611_686_018_427_387_905

get-smi-or-string:
  x := get-smi
  if x == 0: return x
  return get-string
