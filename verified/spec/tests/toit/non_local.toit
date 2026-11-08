// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

find-first list/List [predicate]:
  list.do:
    if predicate.call it: return it
  return null

deep-return:
  3.repeat: | i |
    3.repeat: | j |
      if i == 1 and j == 2: return "found $i $j"
  return "none"

break-out:
  result := 0
  for i := 0; i < 100; i++:
    [1, 2, 3].do:
      if i == 5: return "returned at $i"
      result += it
  return "done $result"

loop-with-break:
  i := 0
  while true:
    [10, 20].do:
      if i > 3: break
    i++
  return i

with-finally [block]:
  try:
    block.call
  finally:
    print "  finally runs"

through-finally:
  with-finally:
    return "through finally"
  return "not reached"

main:
  print (find-first [1, 3, 8, 5, 10]: it % 2 == 0)
  print (find-first [1, 3]: it > 5)
  print deep-return
  print break-out
  print loop-with-break
  print through-finally
  // Non-local branch (continue/break) out of nested blocks.
  out := []
  for i := 0; i < 5; i++:
    [0].do:
      if i == 1: continue
      if i == 4: break
      out.add i
  print out
  // Map iteration with early return.
  m := {"a": 1, "b": 2, "c": 3}
  found := null
  m.do: | k v |
    if v == 2:
      found = k
  print found
