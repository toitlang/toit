// Copyright (C) 2020 Toitware ApS. All rights reserved.

class A:
  static static_field := ?

main args:
  if args.size == -1: A.static_field = 499
  print A.static_field
