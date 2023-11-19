import .registry
import ..semantic-version

class LocalRegistry extends Registry:
  type ::= "local"
  path/string

  constructor name/string .path/string:
    super name

  search search-string/string -> List:
    return []

  retrieve-description url/string version/SemanticVersion -> Description?:
    return null

  retrieve-versions url/string -> List?:
    return null
