// Copyright (C) 2020 Toitware ApS. All rights reserved.

is_verbose / bool := false

verbose [block]:
  if is_verbose:
    print_on_stderr_ block.call
