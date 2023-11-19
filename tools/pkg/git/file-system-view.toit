
class FileSystemView:
  content_/Map

  constructor .content_:

  get --path/List -> any:
    if path.is-empty: return null
    if path.size == 1: return get path[0]

    element := content_.get path[0]
    if not element is Map: return null

    return (FileSystemView element).get --path=path[1..]

  get key/string -> any:
    element := content_.get key
    if element is Map: return FileSystemView element
    return element

  list -> Map:
    return content_.map: | k v | if v is Map: FileSystemView v else: v

