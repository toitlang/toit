flatten_list input/List -> List:
  list := List
  input.do:
    if it is List: list.add-all (flatten_list it)
    else: list.add it
  return list

/**
Assumes that the values in $map are $List.

If the $key is in $map, append the $value to the entry with $key.
If the $key is not in $map, create a new entry for $key as a size one $List with the
  the one element being $value.
*/
append-to-list-value map/Map key value:
  if map.contains key:
    map[key].add value
  else:
    map[key] = [ value ]

/**
Assumes that the values in $map are $Set.

If the $key is in $map, add the $value to the entry with $key.
If the $key is not in $map, create a new entry for $key as a size one $Set with the
  the one element being $value.
*/
add-to-set-value map/Map key value:
  if map.contains key:
    map[key].add value
  else:
    map[key] = { value }