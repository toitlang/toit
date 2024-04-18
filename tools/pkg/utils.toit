// Copyright (C) 2024 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

flatten_list input/List -> List:
  list := List
  input.do:
    if it is List: list.add-all (flatten_list it)
    else: list.add it
  return list

/**
Assumes that the values in $map are of type $List.

If the $key is in $map, append the $value to the entry with $key.
If the $key is not in $map, create a new entry for $key as a size one $List with the
  the one element being $value.
*/
append-to-list-value map/Map key value:
  list := map.get key --init=:[]
  list.add value

/**
Assumes that the values in $map are of type $Set.

If the $key is in $map, add the $value to the entry with $key.
If the $key is not in $map, create a new entry for $key as a size one $Set with the
  the one element being $value.
*/
add-to-set-value map/Map key value:
  set := map.get key --init=:{}
  set.add value
