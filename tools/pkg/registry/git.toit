import encoding.yaml

import ..git
import ..file-system-view
import ..utils
import ..semantic-version
import .registry

class GitRegistry extends Registry:
  type ::= "git"
  url/string
  content_/FileSystemView? := null

  constructor name .url:
    super name

  content -> FileSystemView:
    if not content_: content_ = load_
    return content_

  load_ -> FileSystemView:
    repository := open-repository url
    head-ref/string := repository.head
    pack := repository.clone head-ref
    return pack.content


