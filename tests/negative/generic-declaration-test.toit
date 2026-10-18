// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class Dup<T, T>:

class Tag:

mixin M<T>:

class Conflict<T>:
  T -> int: return 1

class Nested<T>:
  bad/T<int>? := null
  check x -> bool: return x is T
  cast x -> T: return x as T

foo x/List -> none:
bar x/List<int, int> -> none:
gee x/Tag<int> -> none:
too-few x/Map<string> -> none:

main:
  l/List<int> := []
  if l is List<int>: print 1
  a := l as List<string>
  unresolved
