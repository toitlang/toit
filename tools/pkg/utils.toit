flatten_list input/List:
  list := List
  input.do:
    if it is List: list.add-all (flatten_list it)
    else: list.add it
  return list