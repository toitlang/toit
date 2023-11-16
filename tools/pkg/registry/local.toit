import .registry

class LocalRegistry extends Registry:
  type ::= "local"
  path/string

  constructor name/string .path/string:
    super name

  search search-string/string -> List:
    return []

