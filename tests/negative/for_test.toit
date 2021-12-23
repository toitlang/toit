// Copyright (C) 2019 Toitware ApS. All rights reserved.

main:
  for
  for break
    print unresolved
  for break print unresolved
  for "".
  unresolved
 
  for x := 0;
  for x := 0; break
    print unresolved
  for x := 0; break print unresolved
  for x := 0; "".
  unresolved
 
  for x := 0; true;
  for x := 0; true; break
    print unresolved
  for x := 0; true; break print unresolved
  for x := 0; true; "".
  unresolved
 
  for x := 0; true: unresolved
  for x := 0; true; break
    print unresolved
  for x := 0; true; break print : unresolved
  for x := 0; true; "".  : unresolved
  unresolved

  for x := 0; y := 1; x++:
