// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a class finds the references inside block types.
class Item:
/*
      @ def
      ^
  [def, param-type, return-type, local-type]
*/
  value := 0

each list/List [block Item -> Item] -> none:
/*                    @ param-type */
/*                            @ return-type */
  list.do: block.call it

main:
  each []: |item/Item| item
/*               @ local-type */
