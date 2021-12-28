// Copyright (C) 2020 Toitware ApS. All rights reserved.

// We had a bug, where an invalid argument (`local := ? 42`) already
//   reported an error ("Can't call result of expression"), and then
//   happily evaluated the definition of the local, which was then
//   seen by the block.
// Later the block argument was moved in front of the call (which normally
//   works). However, when the type-check analysis then tried to see the
//   type of the `local` the compiler crashed.
// We now make sure that an error (like "Can't call result of expression")
//   won't allow definitions to be visible to elements that come later.

bar x/int:
gee x [y]:

test1:
  "".bar
    local := ? 42
    : bar local

test2:
  gee
    (local := ?) 42
    : bar local
