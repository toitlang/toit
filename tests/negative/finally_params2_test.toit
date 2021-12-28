// Copyright (C) 2020 Toitware ApS. All rights reserved.

main:
  try:
    throw "foo"
  finally: | in_throw exception/int? |
